//! This module defines the struct [EthArenaSender] that is responsible for the sending transactions
//! to tournaments

use async_trait::async_trait;
use std::{str::FromStr, sync::Arc, time::Duration};

use ethers::{
    contract::ContractError,
    middleware::SignerMiddleware,
    providers::{Http, Middleware, Provider, ProviderError},
    signers::{LocalWallet, Signer},
    types::{Address, Bytes},
};

use crate::{
    arena::{arena::MatchID, config::ArenaConfig},
    machine::MachineProof,
};
use cartesi_dave_merkle::{Digest, MerkleProof};
use cartesi_prt_contracts::{leaf_tournament, non_leaf_tournament, tournament};

type SenderMiddleware = SignerMiddleware<Provider<Http>, LocalWallet>;
type Result<T> = std::result::Result<T, ContractError<SenderMiddleware>>;

#[derive(Clone)]
pub struct EthArenaSender {
    client: Arc<SenderMiddleware>,
}

impl EthArenaSender {
    pub fn new(config: ArenaConfig) -> anyhow::Result<Self> {
        let provider = Provider::<Http>::try_from(config.web3_rpc_url.clone())?
            .interval(Duration::from_millis(10u64));
        let wallet = LocalWallet::from_str(config.web3_private_key.as_str())?;
        let client = Arc::new(SignerMiddleware::new(
            provider,
            wallet.with_chain_id(config.web3_chain_id),
        ));

        Ok(Self { client })
    }

    pub async fn nonce(&self) -> std::result::Result<u64, ProviderError> {
        Ok(self
            .client
            .inner()
            .get_transaction_count(self.client.signer().address(), None)
            .await?
            .as_u64())
    }
}

/// The [ArenaSender] trait defines the interface for the creation and management of tournaments.
#[async_trait]
pub trait ArenaSender: Send + Sync {
    async fn join_tournament(
        &self,
        tournament: Address,
        proof: &MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<()>;

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> Result<()>;

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> Result<()>;

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<()>;

    async fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<()>;

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> Result<()>;

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> Result<()>;

    async fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> Result<()>;
}

#[async_trait]
impl ArenaSender for EthArenaSender {
    async fn join_tournament(
        &self,
        tournament: Address,
        proof: &MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<()> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let siblings = proof
            .siblings
            .iter()
            .map(|h| -> [u8; 32] { (*h).into() })
            .collect();
        tournament
            .join_tournament(
                proof.node.into(),
                siblings,
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
    ) -> Result<()> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        tournament
            .advance_match(
                match_id.into(),
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
        initial_hash_proof: &MerkleProof,
    ) -> Result<()> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> [u8; 32] { (*h).into() })
            .collect();
        tournament
            .seal_inner_match_and_create_inner_tournament(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
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
    ) -> Result<()> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        tournament
            .win_inner_match(child_tournament, left_node.into(), right_node.into())
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<()> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        tournament
            .win_match_by_timeout(match_id.into(), left_node.into(), right_node.into())
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
        initial_hash_proof: &MerkleProof,
    ) -> Result<()> {
        let tournament = leaf_tournament::LeafTournament::new(tournament, self.client.clone());
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> [u8; 32] { (*h).into() })
            .collect();
        tournament
            .seal_leaf_match(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
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
    ) -> Result<()> {
        let tournament = leaf_tournament::LeafTournament::new(tournament, self.client.clone());
        tournament
            .win_leaf_match(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                Bytes::from(proofs),
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> Result<()> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        tournament
            .eliminate_match_by_timeout(match_id.into())
            .send()
            .await?
            .await?;
        Ok(())
    }
}
