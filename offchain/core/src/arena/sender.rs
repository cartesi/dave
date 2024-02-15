//! This module defines the struct [EthArenaSender] that is responsible for the sending transactions
//! to tournaments

use std::{error::Error, str::FromStr, sync::Arc, time::Duration};

use async_trait::async_trait;

use ethers::{
    middleware::SignerMiddleware,
    providers::{Http, Provider},
    signers::{LocalWallet, Signer},
    types::{Address, Bytes},
};

use crate::{
    arena::{arena::MatchID, config::ArenaConfig},
    contract::{leaf_tournament, non_leaf_tournament, tournament},
    machine::MachineProof,
    merkle::{Digest, MerkleProof},
};

#[derive(Clone)]
pub struct EthArenaSender {
    client: Arc<SignerMiddleware<Provider<Http>, LocalWallet>>,
}

impl EthArenaSender {
    pub fn new(config: ArenaConfig) -> Result<Self, Box<dyn Error>> {
        let provider = Provider::<Http>::try_from(config.web3_rpc_url.clone())?
            .interval(Duration::from_millis(10u64));
        let wallet = LocalWallet::from_str(config.web3_private_key.as_str())?;
        let client = Arc::new(SignerMiddleware::new(
            provider,
            wallet.with_chain_id(config.web3_chain_id),
        ));

        Ok(Self { client })
    }
}

/// The [ArenaSender] trait defines the interface for the creation and management of tournaments.
#[async_trait]
pub trait ArenaSender: Send + Sync {
    async fn join_tournament(
        &self,
        tournament: Address,
        final_state: Digest,
        proof: MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<(), Box<dyn Error>>;

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> Result<(), Box<dyn Error>>;

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>>;

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<(), Box<dyn Error>>;

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>>;

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> Result<(), Box<dyn Error>>;

    async fn eliminate_match(
        &self,
        tournament: Address,
        match_id: MatchID,
    ) -> Result<(), Box<dyn Error>>;
}

#[async_trait]
impl ArenaSender for EthArenaSender {
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
        let match_id = tournament::Id {
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
        let match_id = non_leaf_tournament::Id {
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
        let match_id = leaf_tournament::Id {
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
        let match_id = leaf_tournament::Id {
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

    async fn eliminate_match(
        &self,
        tournament: Address,
        match_id: MatchID,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let match_id = tournament::Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        tournament
            .eliminate_match_by_timeout(match_id)
            .send()
            .await?
            .await?;
        Ok(())
    }
}
