mod error;

use alloy::{
    primitives::{Address, B256},
    providers::DynProvider,
};
use error::Result;
use log::{info, trace};
use num_traits::cast::ToPrimitive;
use std::{ops::ControlFlow, time::Duration};

use cartesi_dave_contracts::daveconsensus::{self, DaveConsensus};
use cartesi_prt_core::{
    db::compute_state_access::{Input, Leaf},
    strategy::player::Player,
    tournament::{EthArenaSender, allow_revert_rethrow_others},
};
use rollups_state_manager::{Epoch, Proof, StateManager, sync::Watch};

pub struct EpochManager<SM: StateManager> {
    provider: DynProvider,
    arena_sender: EthArenaSender,
    consensus: Address,
    sleep_duration: Duration,
    state_manager: SM,
}

impl<SM: StateManager> EpochManager<SM> {
    pub fn new(
        arena_sender: EthArenaSender,
        provider: DynProvider,
        consensus_address: Address,
        state_manager: SM,
        sleep_duration: Duration,
    ) -> Self {
        Self {
            arena_sender,
            consensus: consensus_address,
            sleep_duration,
            state_manager,
            provider,
        }
    }

    pub fn start(self, watch: Watch) -> Result<()> {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("`EpochManager` runtime build failure");

        rt.block_on(async move { self.execution_loop(watch).await })
    }

    pub async fn execution_loop(mut self, watch: Watch) -> Result<()> {
        let dave_consensus =
            daveconsensus::DaveConsensus::new(self.consensus, self.provider.clone());

        loop {
            self.try_settle_epoch(&dave_consensus).await?;
            self.try_react_epoch().await?;

            if matches!(watch.wait(self.sleep_duration), ControlFlow::Break(_)) {
                break Ok(());
            }
        }
    }

    pub async fn try_settle_epoch(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<(), DynProvider>,
    ) -> Result<()> {
        let can_settle = dave_consensus.canSettle().call().await?;

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

    async fn try_react_epoch(&mut self) -> Result<()> {
        // participate in last sealed epoch tournament
        if let Some(last_sealed_epoch) = self.state_manager.last_sealed_epoch()?
        // .map_err(|err| EpochManagerError::StateManagerError(Box::new(err)))?
        {
            match self
                .state_manager
                .settlement_info(last_sealed_epoch.epoch_number)?
                // .map_err(EpochManagerError::StateManagerError)?
            {
                Some(_) => {
                    info!(
                        "dispute tournaments for epoch {}",
                        last_sealed_epoch.epoch_number
                    );
                    self.react_dispute(&last_sealed_epoch).await?
                }
                None => {
                    trace!("wait for `machine-runner` to insert settlement values");
                }
            }
        }
        Ok(())
    }

    async fn react_dispute(&mut self, last_sealed_epoch: &Epoch) -> Result<()> {
        let Some(snapshot) = self
            .state_manager
            .snapshot_dir(last_sealed_epoch.epoch_number)?
        else {
            trace!("wait for `machine-runner` to save machine snapshot");
            return Ok(());
        };

        let mut player = {
            let inputs = self
                .state_manager
                .inputs(last_sealed_epoch.epoch_number)?
                .into_iter()
                .map(Input)
                .collect();

            let leafs = self
                .state_manager
                .machine_state_hashes(last_sealed_epoch.epoch_number)?
                .into_iter()
                .map(|l| Leaf {
                    hash: l.hash,
                    repetitions: l.repetitions,
                })
                .collect();

            let address = last_sealed_epoch.root_tournament;

            Player::new(
                Some(inputs),
                leafs,
                self.provider.clone(),
                snapshot.to_string_lossy().to_string(),
                address,
                last_sealed_epoch.block_created_number,
                self.state_manager
                    .epoch_directory(last_sealed_epoch.epoch_number)?,
            )
            .expect("fail to initialize prt player")
        };

        player.react_once(&self.arena_sender).await?;
        Ok(())
    }
}

fn to_bytes_32_vec(proof: Proof) -> Vec<B256> {
    proof.inner().iter().map(B256::from).collect()
}

fn vec_u8_to_bytes_32(hash: Vec<u8>) -> B256 {
    B256::from_slice(&hash)
}
