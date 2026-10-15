//! Wire-independent tournament values for the narrow observer and pure planners.
//!
//! These types deliberately contain no generated contract bindings and no raw
//! clock representation. The strict observer validates ABI values and assembles
//! this domain before Hero or GC policy sees them.

use std::num::NonZeroU64;

use alloy::primitives::{Address, U256};
use thiserror::Error;

use crate::merkle::Digest;

/// The ordered pair that identifies one match.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MatchID {
    pub commitment_one: Digest,
    pub commitment_two: Digest,
}

impl MatchID {
    pub fn hash(self) -> Digest {
        self.commitment_one.join(&self.commitment_two)
    }
}

impl From<MatchID> for cartesi_prt_contracts::tournament::Match::Id {
    fn from(match_id: MatchID) -> Self {
        Self {
            commitmentOne: match_id.commitment_one.into(),
            commitmentTwo: match_id.commitment_two.into(),
        }
    }
}

/// One side of the contract's ordered match identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchSide {
    One,
    Two,
}

/// Whether matches in a tournament terminate locally or delegate to a child.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TournamentKind {
    Leaf,
    NonLeaf,
}

/// Immutable geometry and identity owned by one tournament clone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TournamentDescriptor {
    address: Address,
    kind: TournamentKind,
    level: u64,
    initial_hash: Digest,
    base_cycle: U256,
    log2_stride: u64,
    height: NonZeroU64,
}

impl TournamentDescriptor {
    #[allow(clippy::too_many_arguments)]
    pub fn try_new(
        address: Address,
        level: u64,
        kind: TournamentKind,
        initial_hash: Digest,
        base_cycle: U256,
        log2_stride: u64,
        height: u64,
    ) -> Result<Self, DomainError> {
        let height = NonZeroU64::new(height).ok_or(DomainError::ZeroCommitmentHeight)?;
        // The dispute engine represents the full row span as a U256 shift.
        // Extent 256 would wrap that span to zero even if its leaves fit.
        if height.get() >= 256
            || log2_stride >= 256
            || height.get().saturating_add(log2_stride) >= 256
        {
            return Err(DomainError::CoordinateGeometryOutOfRange {
                height: height.get(),
                log2_stride,
            });
        }
        let maximum_leaf_offset = ((U256::from(1) << height.get()) - U256::from(1)) << log2_stride;
        if base_cycle.checked_add(maximum_leaf_offset).is_none() {
            return Err(DomainError::TournamentCycleRangeOverflow);
        }
        Ok(Self {
            address,
            kind,
            level,
            initial_hash,
            base_cycle,
            log2_stride,
            height,
        })
    }

    pub const fn address(self) -> Address {
        self.address
    }

    pub const fn kind(self) -> TournamentKind {
        self.kind
    }

    pub const fn level(self) -> u64 {
        self.level
    }

    pub const fn initial_hash(self) -> Digest {
        self.initial_hash
    }

    pub const fn base_cycle(self) -> U256 {
        self.base_cycle
    }

    pub const fn log2_stride(self) -> u64 {
        self.log2_stride
    }

    pub const fn height(self) -> NonZeroU64 {
        self.height
    }

    pub const fn is_root(self) -> bool {
        self.level == 0
    }
}

/// One contract-authoritative location in a tournament's commitment tree.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MatchCoordinate {
    leaf_position: U256,
    cycle: U256,
}

impl MatchCoordinate {
    pub const fn new(leaf_position: U256, cycle: U256) -> Self {
        Self {
            leaf_position,
            cycle,
        }
    }

    pub const fn leaf_position(self) -> U256 {
        self.leaf_position
    }

    pub const fn cycle(self) -> U256 {
        self.cycle
    }
}

/// The waiting commitment's already revealed children.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WaitingChildren {
    left: Digest,
    right: Digest,
}

impl WaitingChildren {
    pub const fn new(left: Digest, right: Digest) -> Self {
        Self { left, right }
    }

    pub const fn left(self) -> Digest {
        self.left
    }

    pub const fn right(self) -> Digest {
        self.right
    }
}

/// A match still being bisected: what the waiting commitment revealed and
/// where. A bisecting match stands above height 1 (`validate_match_geometry`
/// holds it there); one ready to seal stands at height 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UnresolvedMatch {
    pub revealing_parent: Digest,
    pub waiting_children: WaitingChildren,
    pub coordinate: MatchCoordinate,
    pub height: u64,
    pub responder: MatchSide,
}

/// A sealed first divergence, oriented to the ordered match identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SealedDivergence {
    agree_state: Digest,
    coordinate: MatchCoordinate,
    final_state_one: Digest,
    final_state_two: Digest,
}

impl SealedDivergence {
    pub const fn new(
        agree_state: Digest,
        coordinate: MatchCoordinate,
        final_state_one: Digest,
        final_state_two: Digest,
    ) -> Self {
        Self {
            agree_state,
            coordinate,
            final_state_one,
            final_state_two,
        }
    }

    pub const fn agree_state(self) -> Digest {
        self.agree_state
    }

    pub const fn coordinate(self) -> MatchCoordinate {
        self.coordinate
    }

    pub const fn final_state(self, side: MatchSide) -> Digest {
        match side {
            MatchSide::One => self.final_state_one,
            MatchSide::Two => self.final_state_two,
        }
    }
}

/// The semantic phase of one live match after Leaf/NonLeaf enrichment.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LiveMatchState {
    Bisecting(UnresolvedMatch),
    ReadyToSealLeaf(UnresolvedMatch),
    ReadyToDelegate(UnresolvedMatch),
    SealedLeaf(SealedDivergence),
    /// Delegated to the child tournament at this address.
    AwaitingChild(Address),
}

/// Contract-authoritative timeout resolution in ordered match orientation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimeoutDisposition {
    None,
    OneWins,
    TwoWins,
    EliminateBoth,
}

/// A validated live phase together with its current timeout disposition.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LiveMatch {
    state: LiveMatchState,
    timeout: TimeoutDisposition,
}

impl LiveMatch {
    pub const fn new(state: LiveMatchState, timeout: TimeoutDisposition) -> Self {
        Self { state, timeout }
    }

    pub const fn state(self) -> LiveMatchState {
        self.state
    }

    pub const fn timeout(self) -> TimeoutDisposition {
        self.timeout
    }
}

/// A local commitment's validated engagement in one ordered match.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Engagement {
    match_id: MatchID,
    local_side: MatchSide,
    live: LiveMatch,
}

impl Engagement {
    pub const fn new(match_id: MatchID, local_side: MatchSide, live: LiveMatch) -> Self {
        Self {
            match_id,
            local_side,
            live,
        }
    }

    pub const fn match_id(self) -> MatchID {
        self.match_id
    }

    pub const fn local_side(self) -> MatchSide {
        self.local_side
    }

    pub const fn live(self) -> LiveMatch {
        self.live
    }
}

/// Why a match was resolved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchDeletionReason {
    Step,
    Timeout,
    ChildTournament,
}

/// The fold/view interpretation of the Hero's commitment in one tournament.
// Standings are short-lived values; keeping engagement data inline makes the
// semantic snapshot a straightforward value assembled by the reader.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocalCommitmentStanding {
    NotJoined,
    Candidate,
    Engaged(Engagement),
    Eliminated { reason: MatchDeletionReason },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RootWinner {
    commitment: Digest,
    final_state: Digest,
}

impl RootWinner {
    pub const fn new(commitment: Digest, final_state: Digest) -> Self {
        Self {
            commitment,
            final_state,
        }
    }

    pub const fn commitment(self) -> Digest {
        self.commitment
    }

    pub const fn final_state(self) -> Digest {
        self.final_state
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InnerWinner {
    parent_commitment: Digest,
    child_commitment: Digest,
}

impl InnerWinner {
    pub const fn new(parent_commitment: Digest, child_commitment: Digest) -> Self {
        Self {
            parent_commitment,
            child_commitment,
        }
    }

    pub const fn parent_commitment(self) -> Digest {
        self.parent_commitment
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InnerEliminationReason {
    NoCandidate,
    WinnerExpired { candidate: Digest },
}

/// Current-only tournament result and closure disposition.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TournamentStanding {
    MatchesActive { accepts_joins: bool },
    AwaitingClosure,
    RootWinner(RootWinner),
    RootFailed,
    InnerWinner(InnerWinner),
    InnerEliminable { reason: InnerEliminationReason },
}

impl TournamentStanding {
    pub const fn accepts_joins(self) -> bool {
        matches!(
            self,
            Self::MatchesActive {
                accepts_joins: true
            } | Self::AwaitingClosure
        )
    }
}

/// The fold-owned provenance needed to propagate a child result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ParentLink {
    parent_tournament: Address,
    parent_match: MatchID,
    parent_commitment: Digest,
    parent_side: MatchSide,
}

impl ParentLink {
    pub const fn new(
        parent_tournament: Address,
        parent_match: MatchID,
        parent_commitment: Digest,
        parent_side: MatchSide,
    ) -> Self {
        Self {
            parent_tournament,
            parent_match,
            parent_commitment,
            parent_side,
        }
    }

    pub const fn parent_tournament(self) -> Address {
        self.parent_tournament
    }

    pub const fn parent_commitment(self) -> Digest {
        self.parent_commitment
    }
}

/// One actor-relative tournament observation, recursively enriched along its
/// live child path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SemanticSnapshot {
    descriptor: TournamentDescriptor,
    standing: TournamentStanding,
    local_commitment: Digest,
    local_standing: LocalCommitmentStanding,
    parent: Option<ParentLink>,
    child: Option<Box<SemanticSnapshot>>,
}

impl SemanticSnapshot {
    pub fn new(
        descriptor: TournamentDescriptor,
        standing: TournamentStanding,
        local_commitment: Digest,
        local_standing: LocalCommitmentStanding,
        parent: Option<ParentLink>,
        child: Option<Self>,
    ) -> Self {
        Self {
            descriptor,
            standing,
            local_commitment,
            local_standing,
            parent,
            child: child.map(Box::new),
        }
    }

    pub const fn descriptor(&self) -> TournamentDescriptor {
        self.descriptor
    }

    pub const fn standing(&self) -> TournamentStanding {
        self.standing
    }

    pub const fn local_commitment(&self) -> Digest {
        self.local_commitment
    }

    pub const fn local_standing(&self) -> LocalCommitmentStanding {
        self.local_standing
    }

    pub const fn parent(&self) -> Option<ParentLink> {
        self.parent
    }

    pub fn child(&self) -> Option<&Self> {
        self.child.as_deref()
    }
}

/// Cleanup actions share the semantic locators but never become Hero fallbacks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GcIntent {
    EliminateMatch {
        tournament: Address,
        match_id: MatchID,
    },
    EliminateChild {
        parent_tournament: Address,
        child_tournament: Address,
    },
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum DomainError {
    #[error("commitment height must be nonzero")]
    ZeroCommitmentHeight,
    #[error(
        "commitment coordinate geometry exceeds U256: height {height}, log2 stride {log2_stride}"
    )]
    CoordinateGeometryOutOfRange { height: u64, log2_stride: u64 },
    #[error("tournament base cycle plus its maximum leaf offset exceeds U256")]
    TournamentCycleRangeOverflow,
    #[error("bisecting height must be at least two, got {0}")]
    InvalidBisectingHeight(u64),
    #[error("match remaining height exceeds the tournament commitment height")]
    MatchHeightOutOfRange,
    #[error("match responder disagrees with commitment-height parity")]
    ResponderParityMismatch,
    #[error("match leaf position is outside the tournament commitment tree")]
    MatchPositionOutOfRange,
    #[error("unresolved match position is not aligned to its remaining height")]
    MatchPositionMisaligned,
    #[error("match cycle does not agree with descriptor base cycle and stride")]
    MatchCycleMismatch,
    #[error("recursive child must be exactly one tournament level deeper")]
    ChildLevelMismatch,
    #[error("recursive child base cycle is not on one of its parent's leaves")]
    ChildOutsideParentLeaf,
}

pub(crate) fn validate_match_geometry(
    descriptor: TournamentDescriptor,
    state: LiveMatchState,
) -> Result<(), DomainError> {
    let total_height = descriptor.height().get();

    let (coordinate, unresolved) = match state {
        // The contracts bisect only above height 1. Advancing opens the
        // children of the node one below the contested one (hero/action.rs,
        // prepare_advance), so height 1 would reach the `children` expect in
        // engine/dispute.rs: nonzero is not enough.
        LiveMatchState::Bisecting(value) if value.height < 2 => {
            return Err(DomainError::InvalidBisectingHeight(value.height));
        }
        LiveMatchState::Bisecting(value)
        | LiveMatchState::ReadyToSealLeaf(value)
        | LiveMatchState::ReadyToDelegate(value) => {
            (value.coordinate, Some((value.height, value.responder)))
        }
        LiveMatchState::SealedLeaf(value) => (value.coordinate(), None),
        // No coordinate: the observer bounds the child by this tournament.
        LiveMatchState::AwaitingChild(_) => return Ok(()),
    };

    if let Some((remaining_height, responder)) = unresolved {
        if remaining_height > total_height {
            return Err(DomainError::MatchHeightOutOfRange);
        }
        let advances = total_height - remaining_height;
        let expected_responder = if advances.is_multiple_of(2) {
            MatchSide::One
        } else {
            MatchSide::Two
        };
        if responder != expected_responder {
            return Err(DomainError::ResponderParityMismatch);
        }

        let alignment = U256::from(1) << remaining_height;
        if coordinate.leaf_position() % alignment != U256::ZERO {
            return Err(DomainError::MatchPositionMisaligned);
        }
    }

    let tree_size = U256::from(1) << total_height;
    if coordinate.leaf_position() >= tree_size {
        return Err(DomainError::MatchPositionOutOfRange);
    }

    let scaled_position = coordinate.leaf_position() << descriptor.log2_stride();
    if (scaled_position >> descriptor.log2_stride()) != coordinate.leaf_position() {
        return Err(DomainError::MatchCycleMismatch);
    }
    let Some(expected_cycle) = descriptor.base_cycle().checked_add(scaled_position) else {
        return Err(DomainError::MatchCycleMismatch);
    };
    if coordinate.cycle() != expected_cycle {
        return Err(DomainError::MatchCycleMismatch);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn descriptor(
        address: Address,
        level: u64,
        kind: TournamentKind,
        initial_hash: Digest,
        base_cycle: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            kind,
            initial_hash,
            U256::from(base_cycle),
            3,
            4,
        )
        .unwrap()
    }

    #[test]
    fn descriptor_preserves_authoritative_kind_and_rejects_invalid_geometry() {
        let non_leaf = descriptor(address(1), 0, TournamentKind::NonLeaf, digest(9), 0);
        let leaf = descriptor(address(2), 0, TournamentKind::Leaf, digest(10), 24);
        assert_eq!(non_leaf.kind(), TournamentKind::NonLeaf);
        assert_eq!(leaf.kind(), TournamentKind::Leaf);

        assert_eq!(
            TournamentDescriptor::try_new(
                address(1),
                0,
                TournamentKind::Leaf,
                digest(1),
                U256::ZERO,
                0,
                0,
            ),
            Err(DomainError::ZeroCommitmentHeight)
        );
        assert_eq!(
            TournamentDescriptor::try_new(
                address(1),
                0,
                TournamentKind::Leaf,
                digest(1),
                U256::ZERO,
                253,
                4,
            ),
            Err(DomainError::CoordinateGeometryOutOfRange {
                height: 4,
                log2_stride: 253,
            })
        );
        assert_eq!(
            TournamentDescriptor::try_new(
                address(1),
                0,
                TournamentKind::Leaf,
                digest(1),
                U256::ZERO,
                0,
                256,
            ),
            Err(DomainError::CoordinateGeometryOutOfRange {
                height: 256,
                log2_stride: 0,
            })
        );
        assert_eq!(
            TournamentDescriptor::try_new(
                address(1),
                0,
                TournamentKind::Leaf,
                digest(1),
                U256::ZERO,
                255,
                1,
            ),
            Err(DomainError::CoordinateGeometryOutOfRange {
                height: 1,
                log2_stride: 255,
            })
        );
        assert_eq!(
            TournamentDescriptor::try_new(
                address(1),
                0,
                TournamentKind::Leaf,
                digest(1),
                U256::MAX,
                0,
                1,
            ),
            Err(DomainError::TournamentCycleRangeOverflow)
        );
    }

    #[test]
    fn match_geometry_validates_height_responder_position_and_cycle() {
        let leaf = descriptor(address(1), 0, TournamentKind::Leaf, digest(9), 0);
        let validate = |state| validate_match_geometry(leaf, state);
        let bisecting = |position: u64, cycle: u64, height, responder| {
            LiveMatchState::Bisecting(UnresolvedMatch {
                revealing_parent: digest(3),
                waiting_children: WaitingChildren::new(digest(4), digest(5)),
                coordinate: MatchCoordinate::new(U256::from(position), U256::from(cycle)),
                height,
                responder,
            })
        };
        let sealed = |position: u64, cycle: u64| {
            LiveMatchState::SealedLeaf(SealedDivergence::new(
                digest(10),
                MatchCoordinate::new(U256::from(position), U256::from(cycle)),
                digest(11),
                digest(12),
            ))
        };

        // Advancing opens the children of the node below the contested one,
        // so this bound, not nonzero, fronts the engine's `children` expect.
        for height in [0, 1] {
            assert_eq!(
                validate(bisecting(0, 0, height, MatchSide::One)),
                Err(DomainError::InvalidBisectingHeight(height))
            );
        }
        assert_eq!(validate(bisecting(0, 0, 2, MatchSide::One)), Ok(()));

        assert_eq!(
            validate(bisecting(0, 0, 5, MatchSide::One)),
            Err(DomainError::MatchHeightOutOfRange)
        );
        assert_eq!(
            validate(bisecting(0, 0, 3, MatchSide::One)),
            Err(DomainError::ResponderParityMismatch)
        );
        assert_eq!(
            validate(bisecting(1, 8, 2, MatchSide::One)),
            Err(DomainError::MatchPositionMisaligned)
        );
        assert_eq!(
            validate(sealed(16, 128)),
            Err(DomainError::MatchPositionOutOfRange)
        );
        assert_eq!(
            validate(sealed(3, 25)),
            Err(DomainError::MatchCycleMismatch)
        );
    }
}
