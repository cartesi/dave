mod error;

use alloy::{
    hex::ToHexExt,
    primitives::{Address, B256},
    providers::DynProvider,
};
use error::{EpochManagerError, Result};
use log::{info, trace};
use num_traits::cast::ToPrimitive;
use std::{path::PathBuf, str::FromStr, sync::Arc, time::Duration};

use cartesi_dave_contracts::daveconsensus::{self, DaveConsensus};
use cartesi_prt_core::{
    db::compute_state_access::{Input, Leaf},
    strategy::player::Player,
    tournament::{EthArenaSender, allow_revert_rethrow_others},
};
use rollups_state_manager::{Epoch, Proof, StateManager};

pub struct EpochManager<SM: StateManager> {
    provider: DynProvider,
    arena_sender: EthArenaSender,
    consensus: Address,
    sleep_duration: Duration,
    state_dir: PathBuf,
    state_manager: Arc<SM>,
}

impl<SM: StateManager> EpochManager<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        arena_sender: EthArenaSender,
        provider: DynProvider,
        consensus_address: Address,
        state_manager: Arc<SM>,
        sleep_duration: u64,
        state_dir: PathBuf,
    ) -> Self {
        Self {
            arena_sender,
            consensus: consensus_address,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
            provider,
            state_dir,
        }
    }

    pub async fn start(&self) -> Result<(), SM> {
        let dave_consensus = daveconsensus::DaveConsensus::new(self.consensus, &self.provider);
        loop {
            self.try_settle_epoch(&dave_consensus).await?;
            self.try_react_epoch().await?;
            tokio::time::sleep(self.sleep_duration).await;
        }
    }

    pub async fn try_settle_epoch(
        &self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<(), &DynProvider>,
    ) -> Result<(), SM> {
        let can_settle = dave_consensus.canSettle().call().await?;

        if can_settle.isFinished {
            match self
                .state_manager
                .settlement_info(
                    can_settle
                        .epochNumber
                        .to_u64()
                        .expect("fail to convert epoch number to u64"),
                )
                .map_err(EpochManagerError::StateManagerError)?
            {
                Some((computation_hash, output_merkle, output_proof)) => {
                    assert_eq!(
                        computation_hash,
                        can_settle.winnerCommitment.to_vec(),
                        "Winner commitment mismatch, notify all users!"
                    );
                    info!(
                        "settle epoch {} with claim 0x{}",
                        can_settle.epochNumber,
                        computation_hash.encode_hex()
                    );
                    let tx_result = dave_consensus
                        .settle(
                            can_settle.epochNumber,
                            Self::vec_u8_to_bytes_32(output_merkle),
                            Self::to_bytes_32_vec(output_proof),
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

    async fn try_react_epoch(&self) -> Result<(), SM> {
        // participate in last sealed epoch tournament
        if let Some(last_sealed_epoch) = self
            .state_manager
            .last_sealed_epoch()
            .map_err(EpochManagerError::StateManagerError)?
        {
            match self
                .state_manager
                .settlement_info(last_sealed_epoch.epoch_number)
                .map_err(EpochManagerError::StateManagerError)?
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

    async fn react_dispute(&self, last_sealed_epoch: &Epoch) -> Result<(), SM> {
        let Some(snapshot) = self
            .state_manager
            .snapshot(last_sealed_epoch.epoch_number, 0)
            .map_err(EpochManagerError::StateManagerError)?
        else {
            trace!("wait for `machine-runner` to save machine snapshot");
            return Ok(());
        };

        let inputs = self
            .state_manager
            .inputs(last_sealed_epoch.epoch_number)
            .map_err(EpochManagerError::StateManagerError)?;
        let leafs = self
            .state_manager
            .machine_state_hashes(last_sealed_epoch.epoch_number)
            .map_err(EpochManagerError::StateManagerError)?;

        let mut player = {
            let inputs = Some(inputs.into_iter().map(Input).collect());
            let leafs = leafs
                .into_iter()
                .map(|l| Leaf {
                    hash: l
                        .0
                        .as_slice()
                        .try_into()
                        .expect("fail to convert leafs from machine state hash"),
                    repetitions: l.1,
                })
                .collect();

            let address = Address::from_str(&last_sealed_epoch.root_tournament)
                .expect("fail to convert tournament address from string");

            Player::new(
                inputs,
                leafs,
                self.provider.clone(),
                snapshot,
                address,
                last_sealed_epoch.block_created_number,
                self.state_dir.clone(),
            )
            .expect("fail to initialize prt player")
        };

        player.react_once(&self.arena_sender).await?;
        Ok(())
    }

    fn to_bytes_32_vec(proof: Proof) -> Vec<B256> {
        proof.inner().iter().map(B256::from).collect()
    }

    fn vec_u8_to_bytes_32(hash: Vec<u8>) -> B256 {
        B256::from_slice(&hash)
    }
}
