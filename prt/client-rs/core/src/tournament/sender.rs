//! This module defines the struct [EthArenaSender] that is responsible for the sending transactions
//! to tournaments

use anyhow::Result;
use async_trait::async_trait;
use log::trace;

use alloy::{
    providers::DynProvider,
    sol_types::private::{Address, B256, Bytes},
};

use crate::{machine::MachineProof, tournament::MatchID};
use cartesi_dave_merkle::{Digest, MerkleProof};
use cartesi_prt_contracts::{leaftournament, nonleaftournament, tournament};

#[derive(Clone, Debug)]
pub struct EthArenaSender {
    client: DynProvider,
}

impl EthArenaSender {
    pub fn new(client: DynProvider) -> anyhow::Result<Self> {
        Ok(Self { client })
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
        let tournament = tournament::Tournament::new(tournament, &self.client);
        let siblings = proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        trace!(
            "final state for tournament {} at position {}",
            proof.node, proof.position
        );
        tournament
            .joinTournament(
                proof.node.into(),
                siblings,
                left_child.into(),
                right_child.into(),
            )
            .send()
            .await?
            .watch()
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
        let tournament = tournament::Tournament::new(tournament, &self.client);
        tournament
            .advanceMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                new_left_node.into(),
                new_right_node.into(),
            )
            .send()
            .await?
            .watch()
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
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        tournament
            .sealInnerMatchAndCreateInnerTournament(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .send()
            .await?
            .watch()
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
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        tournament
            .winInnerMatch(child_tournament, left_node.into(), right_node.into())
            .send()
            .await?
            .watch()
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
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        tournament
            .winMatchByTimeout(match_id.into(), left_node.into(), right_node.into())
            .send()
            .await?
            .watch()
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
        let tournament = leaftournament::LeafTournament::new(tournament, &self.client);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        tournament
            .sealLeafMatch(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .send()
            .await?
            .watch()
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
        let tournament = leaftournament::LeafTournament::new(tournament, &self.client);
        tournament
            .winLeafMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                Bytes::from(proofs),
            )
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> Result<()> {
        let tournament = tournament::Tournament::new(tournament, &self.client);
        tournament
            .eliminateMatchByTimeout(match_id.into())
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }
}
