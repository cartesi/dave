//! Module for creation of an Arena in an ethereum node.

use std::{
    collections::HashMap, error::Error, path::Path, str::FromStr, sync::Arc, time::Duration,
};

use async_trait::async_trait;

use ethers::{
    contract::ContractFactory,
    core::abi::Tokenize,
    middleware::SignerMiddleware,
    providers::{Http, Middleware, Provider},
    signers::{LocalWallet, Signer},
    types::{Address as EthersAddress, Bytes, Filter},
};

use crate::{
    arena::*,
    contract::{
        factory::TournamentFactory,
        tournament::{
            leaf_tournament, non_leaf_tournament, non_root_tournament, root_tournament,
            shared_types::Id, tournament,
        },
    },
    machine::{constants, MachineProof},
    merkle::{Digest, MerkleProof},
};

/// The [EthersArena] struct implements the [Arena] trait for an ethereum node.
pub struct EthersArena {
    config: ArenaConfig,
    client: Arc<SignerMiddleware<Provider<Http>, LocalWallet>>,
    tournament_factory: EthersAddress,
    tournament_states: HashMap<Address, Arc<TournamentState>>,
}

impl EthersArena {
    pub fn new(config: ArenaConfig) -> Result<Self, Box<dyn Error>> {
        let provider = Provider::<Http>::try_from(config.web3_rpc_url.clone())?
            .interval(Duration::from_millis(10u64));
        let wallet = LocalWallet::from_str(config.web3_private_key.as_str())?;
        let client = Arc::new(SignerMiddleware::new(
            provider,
            wallet.with_chain_id(config.web3_chain_id),
        ));

        Ok(EthersArena {
            config,
            client,
            tournament_factory: EthersAddress::default(),
            tournament_states: HashMap::new(),
        })
    }

    /// Initializes the arena by deploying the necessary contracts.
    pub async fn init(&mut self) -> Result<(), Box<dyn Error>> {
        // Deploy single level factory.
        let sl_factory_artifact =
            Path::new(self.config.contract_artifacts.single_level_factory.as_str());
        let sl_factory_address = self
            .deploy_contract_from_artifact(sl_factory_artifact, ())
            .await?;

        // Deploy top factory.
        let top_factory_artifact = Path::new(self.config.contract_artifacts.top_factory.as_str());
        let top_factory_address = self
            .deploy_contract_from_artifact(top_factory_artifact, ())
            .await?;

        // Deploy middle factory.
        let middle_factory_artifact =
            Path::new(self.config.contract_artifacts.middle_factory.as_str());
        let middle_factory_address = self
            .deploy_contract_from_artifact(middle_factory_artifact, ())
            .await?;

        // Deploy bottom factory.
        let bottom_factory_artifact =
            Path::new(self.config.contract_artifacts.bottom_factory.as_str());
        let bottom_factory_address = self
            .deploy_contract_from_artifact(bottom_factory_artifact, ())
            .await?;

        // Deploy tournament factory.
        let tournament_factory_artifact =
            Path::new(self.config.contract_artifacts.tournament_factory.as_str());
        self.tournament_factory = self
            .deploy_contract_from_artifact(
                tournament_factory_artifact,
                (
                    sl_factory_address,
                    top_factory_address,
                    middle_factory_address,
                    bottom_factory_address,
                ),
            )
            .await?;

        Ok(())
    }

    /// Deploys a contract from an artifact file and returns its address.
    async fn deploy_contract_from_artifact<T: Tokenize>(
        &self,
        artifact_path: &Path,
        constuctor_args: T,
    ) -> Result<EthersAddress, Box<dyn Error>> {
        let (abi, bytecode) = parse_artifact(artifact_path)?;
        let deployer = ContractFactory::new(abi, bytecode, self.client.clone());
        let contract = deployer
            .deploy(constuctor_args)?
            .confirmations(0usize)
            .send()
            .await?;
        Ok(contract.address())
    }
}

#[async_trait]
impl Arena for EthersArena {
    async fn create_root_tournament(
        &self,
        initial_hash: Digest,
    ) -> Result<Address, Box<dyn Error>> {
        let factory = TournamentFactory::new(self.tournament_factory, self.client.clone());
        factory
            .instantiate_top(initial_hash.into())
            .send()
            .await?
            .await?;

        let filter = Filter::new().from_block(0);
        let logs = self.client.get_logs(&filter).await?;

        // !!!
        println!("{}", logs.len());

        Ok(Address::default())
    }

    async fn join_tournament(
        &self,
        tournament: Address,
        final_state: Digest,
        proof: MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let proof = proof.iter().map(|h| -> [u8; 32] { (*h).into() }).collect();
        tournament
            .join_tournament(
                final_state.into(),
                proof,
                left_child.into(),
                right_child.into(),
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let match_id = Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        tournament
            .advance_match(
                match_id,
                left_node.into(),
                right_node.into(),
                new_left_node.into(),
                new_right_node.into(),
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        let match_id = Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        let initial_hash_proof = initial_hash_proof
            .iter()
            .map(|h| -> [u8; 32] { (*h).into() })
            .collect();
        tournament
            .seal_inner_match_and_create_inner_tournament(
                match_id,
                left_leaf.into(),
                right_leaf.into(),
                initial_hash.into(),
                initial_hash_proof,
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<(), Box<dyn Error>> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        tournament
            .win_inner_match(child_tournament, left_node.into(), right_node.into())
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = leaf_tournament::LeafTournament::new(tournament, self.client.clone());
        let match_id = Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        let initial_hash_proof = initial_hash_proof
            .iter()
            .map(|h| -> [u8; 32] { (*h).into() })
            .collect();
        tournament
            .seal_leaf_match(
                match_id,
                left_leaf.into(),
                right_leaf.into(),
                initial_hash.into(),
                initial_hash_proof,
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = leaf_tournament::LeafTournament::new(tournament, self.client.clone());
        let match_id = Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        tournament
            .win_leaf_match(
                match_id,
                left_node.into(),
                right_node.into(),
                Bytes::from(proofs),
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn created_tournament(
        &self,
        tournament: Address,
        match_id: MatchID,
    ) -> Result<Option<TournamentCreatedEvent>, Box<dyn Error>> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        let events = tournament.new_inner_tournament_filter().query().await?;
        if let Some(event) = events.first() {
            Ok(Some(TournamentCreatedEvent {
                parent_match_id_hash: match_id.hash(),
                new_tournament_address: event.1,
            }))
        } else {
            Ok(None)
        }
    }

    async fn created_matches(
        &self,
        tournament: Address,
    ) -> Result<Vec<MatchCreatedEvent>, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let events = tournament.match_created_filter().query().await?;
        let events: Vec<MatchCreatedEvent> = events
            .iter()
            .map(|event| MatchCreatedEvent {
                id: MatchID {
                    commitment_one: event.two.into(),
                    commitment_two: event.left_of_two.into(),
                },
                left_hash: event.one.into(),
            })
            .collect();
        Ok(events)
    }

    async fn joined_commitments(
        &self,
        tournament: Address,
    ) -> Result<Vec<tournament::CommitmentJoinedFilter>, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let events = tournament.commitment_joined_filter().query().await?;
        Ok(events)
    }

    async fn commitment(
        &self,
        tournament: Address,
        commitment_hash: Digest,
    ) -> Result<(ClockState, Digest), Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let (clock_state, hash) = tournament
            .get_commitment(commitment_hash.into())
            .call()
            .await?;
        let clock_state = ClockState {
            allowance: clock_state.allowance,
            start_instant: clock_state.start_instant,
        };
        Ok((clock_state, Digest::from(hash)))
    }

    async fn tournament_state(
        &mut self,
        tournament_state: TournamentState,
    ) -> Result<Arc<TournamentState>, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament_state.address, self.client.clone());
        let created_matches = self.created_matches(tournament_state.address).await?;
        // let commitments_joined = self.commitment(tournament, commitment_hash);

        let mut matches = vec![];
        for match_event in created_matches {
            let match_id = match_event.id;
            let m = tournament.get_match(match_id.hash().into()).call().await?;

            let running_leaf_position = m.running_leaf_position.as_u64();
            let base = tournament_state.base_big_cycle;
            let step = 1 << constants::LOG2_STEP[tournament_state.level as usize];
            let leaf_cycle = base + (step * running_leaf_position);
            let base_big_cycle = leaf_cycle >> constants::LOG2_UARCH_SPAN;

            if !Digest::from(m.other_parent).is_zeroed() {
                let match_state = self
                    .match_state(
                        tournament_state.level,
                        MatchState {
                            id: match_id,
                            other_parent: m.other_parent.into(),
                            left_node: m.left_node.into(),
                            right_node: m.right_node.into(),
                            running_leaf_position,
                            current_height: m.current_height,
                            tournament: tournament_state.address,
                            level: m.level,
                            leaf_cycle,
                            base_big_cycle,
                            inner_tournament: None,
                        },
                    )
                    .await?;

                matches.push(match_state);
            }
        }

        let mut state = tournament_state.clone();
        state.matches = matches;
        // state.commitments = commitments;

        let arc_state = Arc::new(state);
        self.tournament_states
            .insert(tournament_state.address, arc_state.clone());

        Ok(arc_state)
    }

    async fn match_state(
        &mut self,
        tournament_level: u64,
        match_state: MatchState,
    ) -> Result<MatchState, Box<dyn Error>> {
        let mut state = match_state.clone();
        let created_tournament = self
            .created_tournament(match_state.tournament, match_state.id)
            .await?;
        if let Some(inner) = created_tournament {
            let inner_tournament = TournamentState::new_inner(
                inner.new_tournament_address,
                tournament_level - 1,
                match_state.base_big_cycle,
                match_state.tournament,
            );
            self.tournament_state(inner_tournament).await?;
            state.inner_tournament = Some(inner.new_tournament_address);
        }

        Ok(state)
    }

    async fn root_tournament_winner(
        &self,
        root_tournament: Address,
    ) -> Result<Option<(Digest, Digest)>, Box<dyn Error>> {
        let root_tournament =
            root_tournament::RootTournament::new(root_tournament, self.client.clone());
        let (finished, commitment, state) = root_tournament.arbitration_result().call().await?;
        if finished {
            Ok(Some((Digest::from(commitment), Digest::from(state))))
        } else {
            Ok(None)
        }
    }

    async fn tournament_winner(
        &self,
        tournament: Address,
    ) -> Result<Option<Digest>, Box<dyn Error>> {
        let tournament =
            non_root_tournament::NonRootTournament::new(tournament, self.client.clone());
        let (finished, state) = tournament.inner_tournament_winner().call().await?;
        if finished {
            Ok(Some(Digest::from(state)))
        } else {
            Ok(None)
        }
    }

    async fn maximum_delay(&self, tournament: Address) -> Result<u64, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let delay = tournament.maximum_enforceable_delay().call().await?;
        Ok(delay)
    }
}
