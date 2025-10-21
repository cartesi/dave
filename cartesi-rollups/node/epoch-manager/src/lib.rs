// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod error;

use alloy::{
    primitives::{Address, B256},
    providers::{DynProvider, Provider},
};
use error::Result;
use log::{debug, info, trace};
use num_traits::cast::ToPrimitive;
use std::{ops::ControlFlow, sync::Arc, time::Duration};
use tokio::sync::Mutex;

use cartesi_dave_contracts::dave_consensus::DaveConsensus;
use cartesi_prt_core::{
    db::dispute_state_access::{Input, Leaf},
    strategy::player::Player,
    tournament::{ArenaSender, allow_revert_rethrow_others},
};
use rollups_state_manager::{Epoch, Proof, StateManager, sync::Watch};

pub struct EpochManager<AS: ArenaSender, SM: StateManager> {
    arena_sender: Arc<Mutex<AS>>,
    consensus: Address,
    sleep_duration: Duration,
    state_manager: SM,
    last_react_epoch: (Option<Player<AS>>, u64),
}

impl<AS: ArenaSender, SM: StateManager> EpochManager<AS, SM> {
    pub fn new(
        arena_sender: Arc<Mutex<AS>>,
        consensus_address: Address,
        state_manager: SM,
        sleep_duration: Duration,
    ) -> Self {
        Self {
            arena_sender,
            consensus: consensus_address,
            sleep_duration,
            state_manager,
            last_react_epoch: (None, 0),
        }
    }

    pub async fn execution_loop(mut self, watch: Watch, provider: DynProvider) -> Result<()> {
        let dave_consensus = DaveConsensus::new(self.consensus, provider.clone());

        loop {
            self.try_settle_epoch(&dave_consensus).await?;
            self.try_react_epoch(provider.clone()).await?;

            if matches!(watch.wait(self.sleep_duration), ControlFlow::Break(_)) {
                break Ok(());
            }
        }
    }

    pub async fn try_settle_epoch(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<()> {
        let can_settle = dave_consensus
            .canSettle()
            .block(alloy::eips::BlockId::pending())
            .call()
            .await?;

        if can_settle.isFinished {
            match self.state_manager.settlement_info(
                can_settle
                    .epochNumber
                    .to_u64()
                    .expect("fail to convert epoch number to u64"),
            )? {
                Some(settlement) => {
                    assert_eq!(
                        settlement.computation_hash.data(),
                        can_settle.winnerCommitment,
                        "Winner commitment mismatch, notify all users!"
                    );
                    info!(
                        "settle epoch {} with claim {}",
                        can_settle.epochNumber,
                        settlement.computation_hash.to_hex()
                    );
                    let tx_result = dave_consensus
                        .settle(
                            can_settle.epochNumber,
                            vec_u8_to_bytes_32(settlement.output_merkle.into()),
                            to_bytes_32_vec(settlement.output_proof),
                        )
                        .send()
                        .await;
                    allow_revert_rethrow_others("settle", tx_result).await?;
                }
                None => {
                    trace!("wait for the `machine-runner` to insert the value");
                }
            }
        } else {
            trace!("epoch not ready to be settled");
        }
        Ok(())
    }

    async fn try_react_epoch(&mut self, provider: DynProvider) -> Result<()> {
        // participate in last sealed epoch tournament
        if let Some(last_sealed_epoch) = self.state_manager.last_sealed_epoch()? {
            match self
                .state_manager
                .settlement_info(last_sealed_epoch.epoch_number)?
            {
                Some(_) => {
                    trace!(
                        "dispute tournaments for epoch {}",
                        last_sealed_epoch.epoch_number
                    );
                    self.react_dispute(provider, &last_sealed_epoch).await?
                }
                None => {
                    debug!(
                        "wait for `machine-runner` to insert settlement values for epoch {}",
                        last_sealed_epoch.epoch_number
                    );
                }
            }
        }
        Ok(())
    }

    async fn react_dispute(
        &mut self,
        provider: DynProvider,
        last_sealed_epoch: &Epoch,
    ) -> Result<()> {
        self.get_latest_player(last_sealed_epoch, provider)?;
        self.last_react_epoch
            .0
            .as_mut()
            .expect("prt player should be instantiated")
            .react()
            .await?;

        Ok(())
    }

    fn get_latest_player(
        &mut self,
        last_sealed_epoch: &Epoch,
        provider: DynProvider,
    ) -> Result<()> {
        let snapshot = self
            .state_manager
            .snapshot_dir(last_sealed_epoch.epoch_number, 0)?
            .expect("snapshot is inserted atomically with settlement info");

        // either the player has never been instantiated, or the sealed epoch has advanced
        // we need to instantiate new epoch player with appropriate data
        if self.last_react_epoch.0.is_none()
            || self.last_react_epoch.1 != last_sealed_epoch.epoch_number
        {
            let inputs = self
                .state_manager
                .inputs(last_sealed_epoch.epoch_number)?
                .into_iter()
                .map(Input)
                .collect();

            let leafs = self
                .state_manager
                .epoch_state_hashes(last_sealed_epoch.epoch_number)?
                .into_iter()
                .map(|l| Leaf {
                    hash: l.hash,
                    repetitions: l.repetitions,
                })
                .collect();

            let player = Player::new(
                self.arena_sender.clone(),
                inputs,
                leafs,
                provider.erased(),
                snapshot.to_string_lossy().to_string(),
                last_sealed_epoch.root_tournament,
                last_sealed_epoch.block_created_number,
                self.state_manager
                    .epoch_directory(last_sealed_epoch.epoch_number)?,
            )
            .expect("fail to initialize prt player");

            self.last_react_epoch = (Some(player), last_sealed_epoch.epoch_number);
        }

        Ok(())
    }
}

fn to_bytes_32_vec(proof: Proof) -> Vec<B256> {
    proof.inner().iter().map(B256::from).collect()
}

fn vec_u8_to_bytes_32(hash: Vec<u8>) -> B256 {
    B256::from_slice(&hash)
}
