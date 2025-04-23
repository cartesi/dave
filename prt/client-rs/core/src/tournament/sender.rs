//! This module defines the struct [EthArenaSender] that is responsible for the sending transactions
//! to tournaments

use async_trait::async_trait;
use log::{error, trace};

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
    );

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    );

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    );

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    );

    async fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    );

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    );

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    );

    async fn eliminate_match(&self, tournament: Address, match_id: MatchID);
}

#[async_trait]
impl ArenaSender for EthArenaSender {
    async fn join_tournament(
        &self,
        tournament: Address,
        proof: &MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) {
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
        if let Ok(tx) = tournament
            .joinTournament(
                proof.node.into(),
                siblings,
                left_child.into(),
                right_child.into(),
            )
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to joinTournament {}", e));
        }
    }

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) {
        let tournament = tournament::Tournament::new(tournament, &self.client);
        if let Ok(tx) = tournament
            .advanceMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                new_left_node.into(),
                new_right_node.into(),
            )
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to advanceMatch {}", e));
        }
    }

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) {
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        if let Ok(tx) = tournament
            .sealInnerMatchAndCreateInnerTournament(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to sealInnerMatchAndCreateInnerTournament {}", e));
        }
    }

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) {
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        if let Ok(tx) = tournament
            .winInnerMatch(child_tournament, left_node.into(), right_node.into())
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to winInnerMatch {}", e));
        }
    }

    async fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    ) {
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        if let Ok(tx) = tournament
            .winMatchByTimeout(match_id.into(), left_node.into(), right_node.into())
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to winMatchByTimeout {}", e));
        }
    }

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) {
        let tournament = leaftournament::LeafTournament::new(tournament, &self.client);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        if let Ok(tx) = tournament
            .sealLeafMatch(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to sealLeafMatch {}", e));
        }
    }

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) {
        let tournament = leaftournament::LeafTournament::new(tournament, &self.client);
        if let Ok(tx) = tournament
            .winLeafMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                Bytes::from(proofs),
            )
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to winLeafMatch {}", e));
        }
    }

    async fn eliminate_match(&self, tournament: Address, match_id: MatchID) {
        let tournament = tournament::Tournament::new(tournament, &self.client);
        if let Ok(tx) = tournament
            .eliminateMatchByTimeout(match_id.into())
            .send()
            .await
        {
            let _ = tx
                .watch()
                .await
                .inspect_err(|e| error!("fail to eliminateMatchByTimeout {}", e));
        }
    }
}
