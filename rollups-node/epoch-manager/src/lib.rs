use anyhow::Result;
use ethers::types::Address;
use std::{sync::Arc, time::Duration};

use rollups_state_manager::StateManager;

// TODO: setup constants for commitment builder
pub struct EpochManager<SM: StateManager> {
    consensus: Address,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    // sender: Provider
}

// view methods

// sealedEpoch() -> (epochNumber: uint, canSettle: bool)

// epoch(epochNumber: uint) -> (
//  claim: Option<(bytes32, bool)>, // hash and whether challanged
// )

impl<SM: StateManager> EpochManager<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(consensus_address: Address, state_manager: Arc<SM>, sleep_duration: u64) -> Self {
        Self {
            consensus: consensus_address,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
        }
    }

    pub async fn start(&mut self) -> Result<()> {
        loop {
            // (sealed_epoch_index, can_settle) := ethcall sealedEpoch()

            // if can_settle then send settle_epoch tx

            // claim := ethcall epoch(sealed_epoch_index)
            match self.state_manager.computation_hash(0)? {
                Some(computation_hash) => {
                    // match claim
                    //  + None -> claim
                    //  + Some({x, false}) if x is same as comp_hash -> return;
                    //  + Some({x, false}) if x is not same comp_hash -> claim;
                    //  + Some({_, true}) -> instantiate/join dave;
                }
                None => {
                    // wait for the `machine-runner` to insert the value
                }
            }

            // sleep and come back later
            tokio::time::sleep(self.sleep_duration).await;
        }
    }
}
