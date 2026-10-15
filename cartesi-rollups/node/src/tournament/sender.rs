//! Arena request builders: each dispute verb yields a labeled, fully
//! specified transaction request for the transaction lane. Building is
//! pure; the caller reads the join's bond, and submission belongs to the
//! epoch manager's transaction lane.

use alloy::{
    primitives::{Address, B256, Bytes, U256},
    providers::DynProvider,
};
use log::trace;

use crate::merkle::{Digest, MerkleProof};
use crate::provider::LaneRequest;
use crate::tournament::MatchID;
use cartesi_prt_contracts::tournament;

fn siblings(proof: &MerkleProof) -> Vec<B256> {
    proof
        .siblings
        .iter()
        .map(|h| -> B256 { (*h).into() })
        .collect()
}

pub fn join_tournament(
    provider: &DynProvider,
    tournament: Address,
    proof: &MerkleProof,
    left_child: Digest,
    right_child: Digest,
    bond_value: U256,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
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
            siblings(proof),
            left_child.into(),
            right_child.into(),
        )
        .value(bond_value)
        .into_transaction_request();
    ("joinTournament".to_string(), request)
}

pub fn advance_match(
    provider: &DynProvider,
    tournament: Address,
    match_id: MatchID,
    left_node: Digest,
    right_node: Digest,
    new_left_node: Digest,
    new_right_node: Digest,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .advanceMatch(
            match_id.into(),
            left_node.into(),
            right_node.into(),
            new_left_node.into(),
            new_right_node.into(),
        )
        .into_transaction_request();
    ("advanceMatch".to_string(), request)
}

pub fn seal_inner_match(
    provider: &DynProvider,
    tournament: Address,
    match_id: MatchID,
    left_leaf: Digest,
    right_leaf: Digest,
    initial_hash_proof: &MerkleProof,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .sealInnerMatchAndCreateInnerTournament(
            match_id.into(),
            left_leaf.into(),
            right_leaf.into(),
            initial_hash_proof.node.into(),
            siblings(initial_hash_proof),
        )
        .into_transaction_request();
    (
        "sealInnerMatchAndCreateInnerTournament".to_string(),
        request,
    )
}

pub fn win_inner_match(
    provider: &DynProvider,
    tournament: Address,
    child_tournament: Address,
    left_node: Digest,
    right_node: Digest,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .winInnerTournament(child_tournament, left_node.into(), right_node.into())
        .into_transaction_request();
    ("winInnerTournament".to_string(), request)
}

pub fn win_timeout_match(
    provider: &DynProvider,
    tournament: Address,
    match_id: MatchID,
    left_node: Digest,
    right_node: Digest,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .winMatchByTimeout(match_id.into(), left_node.into(), right_node.into())
        .into_transaction_request();
    ("winMatchByTimeout".to_string(), request)
}

pub fn seal_leaf_match(
    provider: &DynProvider,
    tournament: Address,
    match_id: MatchID,
    left_leaf: Digest,
    right_leaf: Digest,
    initial_hash_proof: &MerkleProof,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .sealLeafMatch(
            match_id.into(),
            left_leaf.into(),
            right_leaf.into(),
            initial_hash_proof.node.into(),
            siblings(initial_hash_proof),
        )
        .into_transaction_request();
    ("sealLeafMatch".to_string(), request)
}

/// `proofs` is a transition witness in chain encoding
/// (Ruler::prove_transition's output).
pub fn win_leaf_match(
    provider: &DynProvider,
    tournament: Address,
    match_id: MatchID,
    left_node: Digest,
    right_node: Digest,
    proofs: Vec<u8>,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .winLeafMatch(
            match_id.into(),
            left_node.into(),
            right_node.into(),
            Bytes::from(proofs),
        )
        .into_transaction_request();
    ("winLeafMatch".to_string(), request)
}

pub fn eliminate_match(
    provider: &DynProvider,
    tournament: Address,
    match_id: MatchID,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .eliminateMatchByTimeout(match_id.into())
        .into_transaction_request();
    ("eliminateMatchByTimeout".to_string(), request)
}

pub fn eliminate_inner_tournament(
    provider: &DynProvider,
    tournament: Address,
    inner_tournament: Address,
) -> LaneRequest {
    let tournament = tournament::Tournament::new(tournament, provider);
    let request = tournament
        .eliminateInnerTournament(inner_tournament)
        .into_transaction_request();
    ("eliminateInnerTournament".to_string(), request)
}
