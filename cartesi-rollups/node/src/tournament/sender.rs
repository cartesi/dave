//! Arena request builders: each dispute verb yields a labeled, fully
//! specified transaction request for the transaction lane. Building is
//! pure; submission belongs to the epoch manager's transaction lane.

use crate::hero::error::Result;
use alloy::{
    eips::BlockId,
    primitives::{Address, B256, Bytes, U256},
    providers::DynProvider,
};
use async_trait::async_trait;
use log::trace;

use crate::provider::LaneRequest;
use crate::tournament::MatchID;

/// A transition witness in chain encoding (Ruler::prove_transition's
/// output).
pub type MachineProof = Vec<u8>;
use crate::merkle::{Digest, MerkleProof};
use cartesi_prt_contracts::tournament;

/// Default gas limit for refundable tournament calls (body + refund modifier overhead;
/// sealInnerMatchAndCreateInnerTournament also creates a contract and needs more).
/// Override with `GAS_LIMIT` env var if needed.
const DEFAULT_GAS_LIMIT: u64 = 15_000_000;

pub(crate) fn gas_limit() -> u64 {
    std::env::var("GAS_LIMIT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_GAS_LIMIT)
}

#[derive(Clone, Debug)]
pub struct EthArenaSender {
    read_provider: DynProvider,
}

impl EthArenaSender {
    pub fn new(read_provider: DynProvider) -> Self {
        Self { read_provider }
    }
}

/// The [ArenaSender] trait names each tournament mutation and yields
/// its lane-ready request. `bond_value` is the one read: the join
/// deposit, pinned at the block of the intent being fulfilled.
#[async_trait]
pub trait ArenaSender: Send + Sync {
    fn join_tournament(
        &self,
        tournament: Address,
        proof: &MerkleProof,
        left_child: Digest,
        right_child: Digest,
        bond_value: U256,
    ) -> LaneRequest;

    fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> LaneRequest;

    fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> LaneRequest;

    fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> LaneRequest;

    fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    ) -> LaneRequest;

    fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> LaneRequest;

    fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> LaneRequest;

    fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> LaneRequest;

    fn eliminate_inner_tournament(
        &self,
        tournament: Address,
        inner_tournament: Address,
    ) -> LaneRequest;

    /// Read the immutable join bond at the same accepted block as the intent
    /// being fulfilled.
    async fn bond_value(&self, tournament: Address, at: BlockId) -> Result<U256>;
}

#[async_trait]
impl ArenaSender for EthArenaSender {
    fn join_tournament(
        &self,
        tournament: Address,
        proof: &MerkleProof,
        left_child: Digest,
        right_child: Digest,
        bond_value: U256,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let siblings = proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        trace!(
            "join tournament {:?} with final_state {} at position {}, left {}, right {}, proof_len {}",
            tournament,
            proof.node,
            proof.position,
            left_child,
            right_child,
            proof.siblings.len()
        );
        let request = tournament
            .joinTournament(
                proof.node.into(),
                siblings,
                left_child.into(),
                right_child.into(),
            )
            .value(bond_value)
            .gas(gas_limit())
            .into_transaction_request();
        ("joinTournament".to_string(), request)
    }

    fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let request = tournament
            .advanceMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                new_left_node.into(),
                new_right_node.into(),
            )
            .gas(gas_limit())
            .into_transaction_request();
        ("advanceMatch".to_string(), request)
    }

    fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        let request = tournament
            .sealInnerMatchAndCreateInnerTournament(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .gas(gas_limit())
            .into_transaction_request();
        (
            "sealInnerMatchAndCreateInnerTournament".to_string(),
            request,
        )
    }

    fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let request = tournament
            .winInnerTournament(child_tournament, left_node.into(), right_node.into())
            .gas(gas_limit())
            .into_transaction_request();
        ("winInnerTournament".to_string(), request)
    }

    fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let request = tournament
            .winMatchByTimeout(match_id.into(), left_node.into(), right_node.into())
            .gas(gas_limit())
            .into_transaction_request();
        ("winMatchByTimeout".to_string(), request)
    }

    fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        let request = tournament
            .sealLeafMatch(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .gas(gas_limit())
            .into_transaction_request();
        ("sealLeafMatch".to_string(), request)
    }

    fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let request = tournament
            .winLeafMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                Bytes::from(proofs),
            )
            .gas(gas_limit())
            .into_transaction_request();
        ("winLeafMatch".to_string(), request)
    }

    fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let request = tournament
            .eliminateMatchByTimeout(match_id.into())
            .gas(gas_limit())
            .into_transaction_request();
        ("eliminateMatchByTimeout".to_string(), request)
    }

    fn eliminate_inner_tournament(
        &self,
        tournament: Address,
        inner_tournament: Address,
    ) -> LaneRequest {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let request = tournament
            .eliminateInnerTournament(inner_tournament)
            .gas(gas_limit())
            .into_transaction_request();
        ("eliminateInnerTournament".to_string(), request)
    }

    async fn bond_value(&self, tournament: Address, at: BlockId) -> Result<U256> {
        let tournament = tournament::Tournament::new(tournament, &self.read_provider);
        let bond_value_result = tournament.bondValue().block(at).call().await?;
        Ok(bond_value_result)
    }
}
