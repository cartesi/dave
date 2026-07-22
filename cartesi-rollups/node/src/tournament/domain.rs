//! Wire-independent tournament values for the semantic reader and pure planners.
//!
//! These types deliberately contain no generated contract bindings and no raw
//! clock representation. The strict adapter validates ABI values and assembles
//! this domain before Hero or GC policy sees them.

use std::num::NonZeroU64;

use alloy::primitives::{Address, U256};
use thiserror::Error;

use crate::merkle::Digest;

use super::types::MatchID;

/// A duration in the tournament's block-number time coordinate.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BlockDuration(u64);

impl BlockDuration {
    pub const ZERO: Self = Self(0);

    pub const fn from_blocks(blocks: u64) -> Self {
        Self(blocks)
    }

    pub const fn blocks(self) -> u64 {
        self.0
    }
}

/// One side of the contract's ordered match identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchSide {
    One,
    Two,
}

impl MatchSide {
    pub const fn opposite(self) -> Self {
        match self {
            Self::One => Self::Two,
            Self::Two => Self::One,
        }
    }

    pub const fn commitment(self, match_id: MatchID) -> Digest {
        match self {
            Self::One => match_id.commitment_one,
            Self::Two => match_id.commitment_two,
        }
    }
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
    levels: NonZeroU64,
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
        levels: u64,
        initial_hash: Digest,
        base_cycle: U256,
        log2_stride: u64,
        height: u64,
    ) -> Result<Self, DomainError> {
        let levels = NonZeroU64::new(levels).ok_or(DomainError::ZeroTournamentLevels)?;
        if level >= levels.get() {
            return Err(DomainError::TournamentLevelOutOfRange {
                level,
                levels: levels.get(),
            });
        }
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
        let kind = if level + 1 == levels.get() {
            TournamentKind::Leaf
        } else {
            TournamentKind::NonLeaf
        };

        Ok(Self {
            address,
            kind,
            level,
            levels,
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

    pub const fn levels(self) -> NonZeroU64 {
        self.levels
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct UnresolvedMatch {
    revealing_parent: Digest,
    waiting_children: WaitingChildren,
    coordinate: MatchCoordinate,
    remaining_height: NonZeroU64,
    responder: MatchSide,
}

impl UnresolvedMatch {
    fn new(
        revealing_parent: Digest,
        waiting_children: WaitingChildren,
        coordinate: MatchCoordinate,
        remaining_height: NonZeroU64,
        responder: MatchSide,
    ) -> Self {
        Self {
            revealing_parent,
            waiting_children,
            coordinate,
            remaining_height,
            responder,
        }
    }
}

/// A match whose next response advances the bisection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BisectingMatch(UnresolvedMatch);

impl BisectingMatch {
    pub fn try_new(
        revealing_parent: Digest,
        waiting_children: WaitingChildren,
        coordinate: MatchCoordinate,
        remaining_height: u64,
        responder: MatchSide,
    ) -> Result<Self, DomainError> {
        if remaining_height < 2 {
            return Err(DomainError::InvalidBisectingHeight(remaining_height));
        }
        let remaining_height =
            NonZeroU64::new(remaining_height).expect("height was checked as positive");
        Ok(Self(UnresolvedMatch::new(
            revealing_parent,
            waiting_children,
            coordinate,
            remaining_height,
            responder,
        )))
    }

    pub const fn revealing_parent(self) -> Digest {
        self.0.revealing_parent
    }

    pub const fn waiting_children(self) -> WaitingChildren {
        self.0.waiting_children
    }

    pub const fn coordinate(self) -> MatchCoordinate {
        self.0.coordinate
    }

    pub const fn remaining_height(self) -> NonZeroU64 {
        self.0.remaining_height
    }

    pub const fn responder(self) -> MatchSide {
        self.0.responder
    }
}

/// A height-one match whose responder must seal its first divergent leaf.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReadyToSealMatch(UnresolvedMatch);

impl ReadyToSealMatch {
    pub fn new(
        revealing_parent: Digest,
        waiting_children: WaitingChildren,
        coordinate: MatchCoordinate,
        responder: MatchSide,
    ) -> Self {
        Self(UnresolvedMatch::new(
            revealing_parent,
            waiting_children,
            coordinate,
            NonZeroU64::new(1).expect("one is nonzero"),
            responder,
        ))
    }

    pub const fn revealing_parent(self) -> Digest {
        self.0.revealing_parent
    }

    pub const fn waiting_children(self) -> WaitingChildren {
        self.0.waiting_children
    }

    pub const fn coordinate(self) -> MatchCoordinate {
        self.0.coordinate
    }

    pub const fn responder(self) -> MatchSide {
        self.0.responder
    }
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

    pub const fn final_state_one(self) -> Digest {
        self.final_state_one
    }

    pub const fn final_state_two(self) -> Digest {
        self.final_state_two
    }

    pub const fn final_state(self, side: MatchSide) -> Digest {
        match side {
            MatchSide::One => self.final_state_one,
            MatchSide::Two => self.final_state_two,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SealedLeafMatch {
    divergence: SealedDivergence,
}

impl SealedLeafMatch {
    pub const fn new(divergence: SealedDivergence) -> Self {
        Self { divergence }
    }

    pub const fn divergence(self) -> SealedDivergence {
        self.divergence
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AwaitingChildMatch {
    divergence: SealedDivergence,
    child_tournament: Address,
}

impl AwaitingChildMatch {
    pub fn try_new(
        divergence: SealedDivergence,
        child_tournament: Address,
    ) -> Result<Self, DomainError> {
        if child_tournament == Address::ZERO {
            return Err(DomainError::ZeroChildTournament);
        }
        Ok(Self {
            divergence,
            child_tournament,
        })
    }

    pub const fn divergence(self) -> SealedDivergence {
        self.divergence
    }

    pub const fn child_tournament(self) -> Address {
        self.child_tournament
    }
}

/// The semantic phase of one live match after Leaf/NonLeaf enrichment.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LiveMatchState {
    Bisecting(BisectingMatch),
    ReadyToSealLeaf(ReadyToSealMatch),
    ReadyToDelegate(ReadyToSealMatch),
    SealedLeaf(SealedLeafMatch),
    AwaitingChild(AwaitingChildMatch),
}

impl LiveMatchState {
    pub const fn responder(self) -> Option<MatchSide> {
        match self {
            Self::Bisecting(value) => Some(value.responder()),
            Self::ReadyToSealLeaf(value) | Self::ReadyToDelegate(value) => Some(value.responder()),
            Self::SealedLeaf(_) | Self::AwaitingChild(_) => None,
        }
    }
}

/// Contract-authoritative timeout resolution in ordered match orientation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimeoutDisposition {
    None,
    OneWins { deferred_charge: BlockDuration },
    TwoWins { deferred_charge: BlockDuration },
    EliminateBoth,
}

impl TimeoutDisposition {
    pub const fn winner(self) -> Option<(MatchSide, BlockDuration)> {
        match self {
            Self::OneWins { deferred_charge } => Some((MatchSide::One, deferred_charge)),
            Self::TwoWins { deferred_charge } => Some((MatchSide::Two, deferred_charge)),
            Self::None | Self::EliminateBoth => None,
        }
    }
}

/// A validated live phase together with its current timeout disposition.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LiveMatch {
    state: LiveMatchState,
    timeout: TimeoutDisposition,
}

impl LiveMatch {
    pub fn try_new(
        state: LiveMatchState,
        timeout: TimeoutDisposition,
    ) -> Result<Self, DomainError> {
        if matches!(state, LiveMatchState::AwaitingChild(_)) && timeout != TimeoutDisposition::None
        {
            return Err(DomainError::AwaitingChildHasTimeout);
        }
        validate_timeout_shape(state, timeout)?;
        Ok(Self { state, timeout })
    }

    pub const fn state(self) -> LiveMatchState {
        self.state
    }

    pub const fn timeout(self) -> TimeoutDisposition {
        self.timeout
    }

    /// Validate this match against the immutable geometry and kind of its
    /// containing tournament.
    pub fn validate_in(self, descriptor: TournamentDescriptor) -> Result<Self, DomainError> {
        validate_match_kind(descriptor.kind(), self.state)?;
        validate_match_geometry(descriptor, self.state)?;
        Ok(self)
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
    pub fn try_new(
        local_commitment: Digest,
        match_id: MatchID,
        state: LiveMatchState,
        timeout: TimeoutDisposition,
    ) -> Result<Self, DomainError> {
        let local_side = side_for(local_commitment, match_id)?;
        let live = LiveMatch::try_new(state, timeout)?;
        Ok(Self {
            match_id,
            local_side,
            live,
        })
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EliminationReason {
    Step,
    Timeout,
    ChildTournament,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EliminationRecord {
    match_id: MatchID,
    local_side: MatchSide,
    reason: EliminationReason,
    survivor: Option<MatchSide>,
}

impl EliminationRecord {
    pub fn try_new(
        local_commitment: Digest,
        match_id: MatchID,
        reason: EliminationReason,
        survivor: Option<MatchSide>,
    ) -> Result<Self, DomainError> {
        let local_side = side_for(local_commitment, match_id)?;
        if survivor == Some(local_side) {
            return Err(DomainError::SurvivorMarkedEliminated);
        }
        if reason == EliminationReason::Step && survivor.is_none() {
            return Err(DomainError::StepDeletionMissingSurvivor);
        }
        Ok(Self {
            match_id,
            local_side,
            reason,
            survivor,
        })
    }

    pub const fn match_id(self) -> MatchID {
        self.match_id
    }

    pub const fn local_side(self) -> MatchSide {
        self.local_side
    }

    pub const fn reason(self) -> EliminationReason {
        self.reason
    }

    pub const fn survivor(self) -> Option<MatchSide> {
        self.survivor
    }
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
    Eliminated(EliminationRecord),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JoinDisposition {
    Open,
    Closed,
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

    pub const fn child_commitment(self) -> Digest {
        self.child_commitment
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
    MatchesActive {
        candidate: Option<Digest>,
        joins: JoinDisposition,
    },
    AwaitingClosure {
        candidate: Option<Digest>,
    },
    RootWinner(RootWinner),
    RootFailed,
    InnerWinner(InnerWinner),
    InnerEliminable {
        reason: InnerEliminationReason,
    },
}

impl TournamentStanding {
    pub const fn candidate(self) -> Option<Digest> {
        match self {
            Self::MatchesActive { candidate, .. } | Self::AwaitingClosure { candidate } => {
                candidate
            }
            Self::RootWinner(winner) => Some(winner.commitment()),
            Self::RootFailed => None,
            Self::InnerWinner(winner) => Some(winner.child_commitment()),
            Self::InnerEliminable {
                reason: InnerEliminationReason::NoCandidate,
            } => None,
            Self::InnerEliminable {
                reason: InnerEliminationReason::WinnerExpired { candidate },
            } => Some(candidate),
        }
    }

    pub const fn accepts_joins(self) -> bool {
        match self {
            Self::MatchesActive {
                joins: JoinDisposition::Open,
                ..
            }
            | Self::AwaitingClosure { .. } => true,
            Self::MatchesActive {
                joins: JoinDisposition::Closed,
                ..
            }
            | Self::RootWinner(_)
            | Self::RootFailed
            | Self::InnerWinner(_)
            | Self::InnerEliminable { .. } => false,
        }
    }

    pub const fn has_active_matches(self) -> bool {
        matches!(self, Self::MatchesActive { .. })
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
    pub fn try_new(
        parent_tournament: Address,
        parent_match: MatchID,
        parent_commitment: Digest,
    ) -> Result<Self, DomainError> {
        let parent_side = side_for(parent_commitment, parent_match)?;
        Ok(Self {
            parent_tournament,
            parent_match,
            parent_commitment,
            parent_side,
        })
    }

    pub const fn parent_tournament(self) -> Address {
        self.parent_tournament
    }

    pub const fn parent_match(self) -> MatchID {
        self.parent_match
    }

    pub const fn parent_commitment(self) -> Digest {
        self.parent_commitment
    }

    pub const fn parent_side(self) -> MatchSide {
        self.parent_side
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
    pub fn try_new(
        descriptor: TournamentDescriptor,
        standing: TournamentStanding,
        local_commitment: Digest,
        local_standing: LocalCommitmentStanding,
        parent: Option<ParentLink>,
        child: Option<Self>,
    ) -> Result<Self, DomainError> {
        validate_standing_kind(descriptor, standing)?;

        match (descriptor.is_root(), parent.is_some()) {
            (true, true) => return Err(DomainError::RootHasParent),
            (false, false) => return Err(DomainError::InnerMissingParent),
            _ => {}
        }

        if let (TournamentStanding::InnerWinner(winner), Some(parent)) = (standing, parent) {
            let parent_match = parent.parent_match();
            if winner.parent_commitment() != parent_match.commitment_one
                && winner.parent_commitment() != parent_match.commitment_two
            {
                return Err(DomainError::InnerWinnerOutsideParentMatch);
            }
        }

        let local_is_candidate = matches!(local_standing, LocalCommitmentStanding::Candidate);
        if (standing.candidate() == Some(local_commitment)) != local_is_candidate {
            return Err(DomainError::LocalCandidateMismatch);
        }

        if matches!(local_standing, LocalCommitmentStanding::Engaged(_))
            && !standing.has_active_matches()
        {
            return Err(DomainError::EngagementWithoutActiveMatches);
        }
        if let LocalCommitmentStanding::Eliminated(record) = local_standing
            && record.local_side().commitment(record.match_id()) != local_commitment
        {
            return Err(DomainError::EliminationCommitmentMismatch);
        }

        let awaiting_child = match local_standing {
            LocalCommitmentStanding::Engaged(engagement) => {
                if engagement.local_side().commitment(engagement.match_id()) != local_commitment {
                    return Err(DomainError::EngagementCommitmentMismatch);
                }
                validate_match_kind(descriptor.kind(), engagement.live().state())?;
                validate_match_geometry(descriptor, engagement.live().state())?;
                match engagement.live().state() {
                    LiveMatchState::AwaitingChild(value) => Some((engagement, value)),
                    _ => None,
                }
            }
            _ => None,
        };

        match (awaiting_child, child.as_ref()) {
            (None, None) => {}
            (None, Some(_)) => return Err(DomainError::UnexpectedChildSnapshot),
            (Some(_), None) => return Err(DomainError::MissingChildSnapshot),
            (Some((engagement, awaiting)), Some(child)) => {
                validate_child(descriptor, local_commitment, engagement, awaiting, child)?;
            }
        }

        Ok(Self {
            descriptor,
            standing,
            local_commitment,
            local_standing,
            parent,
            child: child.map(Box::new),
        })
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
    #[error("tournament level count must be nonzero")]
    ZeroTournamentLevels,
    #[error("tournament level {level} is outside level count {levels}")]
    TournamentLevelOutOfRange { level: u64, levels: u64 },
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
    #[error("a match cannot contain the same commitment twice")]
    DuplicateMatchCommitment,
    #[error("local commitment {commitment} is not in the supplied match")]
    CommitmentNotInMatch { commitment: Digest },
    #[error("an awaiting-child match cannot have a parent-match timeout")]
    AwaitingChildHasTimeout,
    #[error("an active timeout winner cannot be the running responder")]
    ActiveTimeoutWinnerIsResponder,
    #[error("a sealed-leaf timeout winner cannot carry a deferred charge")]
    SealedLeafDeferredCharge,
    #[error("an elimination record cannot eliminate the recorded survivor")]
    SurvivorMarkedEliminated,
    #[error("a step deletion must record one surviving commitment")]
    StepDeletionMissingSurvivor,
    #[error("child tournament address must be nonzero")]
    ZeroChildTournament,
    #[error("root tournament snapshot cannot carry a parent link")]
    RootHasParent,
    #[error("non-root tournament snapshot requires a parent link")]
    InnerMissingParent,
    #[error("root-only standing used for a non-root tournament")]
    RootStandingForInner,
    #[error("inner-only standing used for a root tournament")]
    InnerStandingForRoot,
    #[error("inner winner does not map to either side of the recorded parent match")]
    InnerWinnerOutsideParentMatch,
    #[error("local candidate identity disagrees with tournament standing")]
    LocalCandidateMismatch,
    #[error("a local engagement requires an active-match tournament standing")]
    EngagementWithoutActiveMatches,
    #[error("local engagement identity disagrees with the snapshot commitment")]
    EngagementCommitmentMismatch,
    #[error("local elimination identity disagrees with the snapshot commitment")]
    EliminationCommitmentMismatch,
    #[error("match state does not agree with the immutable tournament kind")]
    MatchKindMismatch,
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
    #[error("snapshot carries a child outside an awaiting-child engagement")]
    UnexpectedChildSnapshot,
    #[error("awaiting-child engagement is missing its recursive child snapshot")]
    MissingChildSnapshot,
    #[error("recursive child address disagrees with the parent match")]
    ChildAddressMismatch,
    #[error("recursive child provenance disagrees with the parent snapshot")]
    ChildProvenanceMismatch,
    #[error("recursive child must be exactly one tournament level deeper")]
    ChildLevelMismatch,
    #[error("recursive child and parent disagree on the tournament level count")]
    ChildLevelCountMismatch,
    #[error("recursive child initial hash disagrees with the sealed agree state")]
    ChildInitialHashMismatch,
    #[error("recursive child base cycle disagrees with the sealed match cycle")]
    ChildBaseCycleMismatch,
}

fn side_for(commitment: Digest, match_id: MatchID) -> Result<MatchSide, DomainError> {
    if match_id.commitment_one == match_id.commitment_two {
        return Err(DomainError::DuplicateMatchCommitment);
    }
    if commitment == match_id.commitment_one {
        Ok(MatchSide::One)
    } else if commitment == match_id.commitment_two {
        Ok(MatchSide::Two)
    } else {
        Err(DomainError::CommitmentNotInMatch { commitment })
    }
}

fn validate_standing_kind(
    descriptor: TournamentDescriptor,
    standing: TournamentStanding,
) -> Result<(), DomainError> {
    match standing {
        TournamentStanding::RootWinner(_) | TournamentStanding::RootFailed
            if !descriptor.is_root() =>
        {
            Err(DomainError::RootStandingForInner)
        }
        TournamentStanding::InnerWinner(_) | TournamentStanding::InnerEliminable { .. }
            if descriptor.is_root() =>
        {
            Err(DomainError::InnerStandingForRoot)
        }
        _ => Ok(()),
    }
}

fn validate_match_kind(kind: TournamentKind, state: LiveMatchState) -> Result<(), DomainError> {
    let agrees = matches!(
        (kind, state),
        (TournamentKind::Leaf, LiveMatchState::Bisecting(_))
            | (TournamentKind::Leaf, LiveMatchState::ReadyToSealLeaf(_))
            | (TournamentKind::Leaf, LiveMatchState::SealedLeaf(_))
            | (TournamentKind::NonLeaf, LiveMatchState::Bisecting(_))
            | (TournamentKind::NonLeaf, LiveMatchState::ReadyToDelegate(_))
            | (TournamentKind::NonLeaf, LiveMatchState::AwaitingChild(_))
    );
    if agrees {
        Ok(())
    } else {
        Err(DomainError::MatchKindMismatch)
    }
}

fn validate_timeout_shape(
    state: LiveMatchState,
    timeout: TimeoutDisposition,
) -> Result<(), DomainError> {
    match (state, timeout) {
        (LiveMatchState::Bisecting(value), TimeoutDisposition::OneWins { .. })
            if value.responder() == MatchSide::One =>
        {
            Err(DomainError::ActiveTimeoutWinnerIsResponder)
        }
        (LiveMatchState::Bisecting(value), TimeoutDisposition::TwoWins { .. })
            if value.responder() == MatchSide::Two =>
        {
            Err(DomainError::ActiveTimeoutWinnerIsResponder)
        }
        (
            LiveMatchState::ReadyToSealLeaf(value) | LiveMatchState::ReadyToDelegate(value),
            TimeoutDisposition::OneWins { .. },
        ) if value.responder() == MatchSide::One => {
            Err(DomainError::ActiveTimeoutWinnerIsResponder)
        }
        (
            LiveMatchState::ReadyToSealLeaf(value) | LiveMatchState::ReadyToDelegate(value),
            TimeoutDisposition::TwoWins { .. },
        ) if value.responder() == MatchSide::Two => {
            Err(DomainError::ActiveTimeoutWinnerIsResponder)
        }
        (
            LiveMatchState::SealedLeaf(_),
            TimeoutDisposition::OneWins { deferred_charge }
            | TimeoutDisposition::TwoWins { deferred_charge },
        ) if deferred_charge != BlockDuration::ZERO => Err(DomainError::SealedLeafDeferredCharge),
        _ => Ok(()),
    }
}

fn validate_match_geometry(
    descriptor: TournamentDescriptor,
    state: LiveMatchState,
) -> Result<(), DomainError> {
    let total_height = descriptor.height().get();

    let (coordinate, unresolved) = match state {
        LiveMatchState::Bisecting(value) => (
            value.coordinate(),
            Some((value.remaining_height().get(), value.responder())),
        ),
        LiveMatchState::ReadyToSealLeaf(value) | LiveMatchState::ReadyToDelegate(value) => {
            (value.coordinate(), Some((1, value.responder())))
        }
        LiveMatchState::SealedLeaf(value) => (value.divergence().coordinate(), None),
        LiveMatchState::AwaitingChild(value) => (value.divergence().coordinate(), None),
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

fn validate_child(
    descriptor: TournamentDescriptor,
    local_commitment: Digest,
    engagement: Engagement,
    awaiting: AwaitingChildMatch,
    child: &SemanticSnapshot,
) -> Result<(), DomainError> {
    if child.descriptor.address() != awaiting.child_tournament() {
        return Err(DomainError::ChildAddressMismatch);
    }

    let expected_parent = ParentLink::try_new(
        descriptor.address(),
        engagement.match_id(),
        local_commitment,
    )
    .expect("the validated engagement contains the local commitment");
    if child.parent != Some(expected_parent) {
        return Err(DomainError::ChildProvenanceMismatch);
    }

    if child.descriptor.level() != descriptor.level() + 1 {
        return Err(DomainError::ChildLevelMismatch);
    }
    if child.descriptor.levels() != descriptor.levels() {
        return Err(DomainError::ChildLevelCountMismatch);
    }

    let divergence = awaiting.divergence();
    if child.descriptor.initial_hash() != divergence.agree_state() {
        return Err(DomainError::ChildInitialHashMismatch);
    }
    if child.descriptor.base_cycle() != divergence.coordinate().cycle() {
        return Err(DomainError::ChildBaseCycleMismatch);
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
        levels: u64,
        initial_hash: Digest,
        base_cycle: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            levels,
            initial_hash,
            U256::from(base_cycle),
            3,
            4,
        )
        .unwrap()
    }

    fn match_id() -> MatchID {
        MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        }
    }

    fn divergence() -> SealedDivergence {
        SealedDivergence::new(
            digest(10),
            MatchCoordinate::new(U256::from(3), U256::from(24)),
            digest(11),
            digest(12),
        )
    }

    fn snapshot_with_engagement(
        descriptor: TournamentDescriptor,
        state: LiveMatchState,
        timeout: TimeoutDisposition,
    ) -> Result<SemanticSnapshot, DomainError> {
        let engagement = Engagement::try_new(digest(1), match_id(), state, timeout)?;
        SemanticSnapshot::try_new(
            descriptor,
            TournamentStanding::MatchesActive {
                candidate: Some(digest(99)),
                joins: JoinDisposition::Closed,
            },
            digest(1),
            LocalCommitmentStanding::Engaged(engagement),
            None,
            None,
        )
    }

    #[test]
    fn descriptor_derives_kind_and_rejects_invalid_geometry() {
        let non_leaf = descriptor(address(1), 0, 2, digest(9), 0);
        let leaf = descriptor(address(2), 1, 2, digest(10), 24);
        assert_eq!(non_leaf.kind(), TournamentKind::NonLeaf);
        assert_eq!(leaf.kind(), TournamentKind::Leaf);

        assert_eq!(
            TournamentDescriptor::try_new(address(1), 0, 0, digest(1), U256::ZERO, 0, 1,),
            Err(DomainError::ZeroTournamentLevels)
        );
        assert_eq!(
            TournamentDescriptor::try_new(address(1), 2, 2, digest(1), U256::ZERO, 0, 1,),
            Err(DomainError::TournamentLevelOutOfRange {
                level: 2,
                levels: 2
            })
        );
        assert_eq!(
            TournamentDescriptor::try_new(address(1), 0, 1, digest(1), U256::ZERO, 0, 0,),
            Err(DomainError::ZeroCommitmentHeight)
        );
        assert_eq!(
            TournamentDescriptor::try_new(address(1), 0, 1, digest(1), U256::ZERO, 253, 4,),
            Err(DomainError::CoordinateGeometryOutOfRange {
                height: 4,
                log2_stride: 253,
            })
        );
        assert_eq!(
            TournamentDescriptor::try_new(address(1), 0, 1, digest(1), U256::ZERO, 0, 256,),
            Err(DomainError::CoordinateGeometryOutOfRange {
                height: 256,
                log2_stride: 0,
            })
        );
        assert_eq!(
            TournamentDescriptor::try_new(address(1), 0, 1, digest(1), U256::ZERO, 255, 1,),
            Err(DomainError::CoordinateGeometryOutOfRange {
                height: 1,
                log2_stride: 255,
            })
        );
        assert_eq!(
            TournamentDescriptor::try_new(address(1), 0, 1, digest(1), U256::MAX, 0, 1,),
            Err(DomainError::TournamentCycleRangeOverflow)
        );
    }

    #[test]
    fn engagement_validates_identity_and_awaiting_child_timeout() {
        let ready = ReadyToSealMatch::new(
            digest(3),
            WaitingChildren::new(digest(4), digest(5)),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            MatchSide::One,
        );
        assert_eq!(
            Engagement::try_new(
                digest(9),
                match_id(),
                LiveMatchState::ReadyToSealLeaf(ready),
                TimeoutDisposition::None,
            ),
            Err(DomainError::CommitmentNotInMatch {
                commitment: digest(9)
            })
        );

        let awaiting =
            AwaitingChildMatch::try_new(divergence(), address(3)).expect("nonzero child");
        assert_eq!(
            Engagement::try_new(
                digest(1),
                match_id(),
                LiveMatchState::AwaitingChild(awaiting),
                TimeoutDisposition::OneWins {
                    deferred_charge: BlockDuration::ZERO,
                },
            ),
            Err(DomainError::AwaitingChildHasTimeout)
        );
    }

    #[test]
    fn snapshot_validates_leaf_enrichment_and_candidate_identity() {
        let root = descriptor(address(1), 0, 1, digest(9), 0);
        let ready = ReadyToSealMatch::new(
            digest(3),
            WaitingChildren::new(digest(4), digest(5)),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            MatchSide::One,
        );
        let engagement = Engagement::try_new(
            digest(1),
            match_id(),
            LiveMatchState::ReadyToDelegate(ready),
            TimeoutDisposition::None,
        )
        .unwrap();
        assert_eq!(
            SemanticSnapshot::try_new(
                root,
                TournamentStanding::MatchesActive {
                    candidate: None,
                    joins: JoinDisposition::Open,
                },
                digest(1),
                LocalCommitmentStanding::Engaged(engagement),
                None,
                None,
            ),
            Err(DomainError::MatchKindMismatch)
        );

        assert_eq!(
            SemanticSnapshot::try_new(
                root,
                TournamentStanding::AwaitingClosure {
                    candidate: Some(digest(1)),
                },
                digest(1),
                LocalCommitmentStanding::NotJoined,
                None,
                None,
            ),
            Err(DomainError::LocalCandidateMismatch)
        );

        let ready = ReadyToSealMatch::new(
            digest(3),
            WaitingChildren::new(digest(4), digest(5)),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            MatchSide::One,
        );
        let engagement = Engagement::try_new(
            digest(1),
            match_id(),
            LiveMatchState::ReadyToSealLeaf(ready),
            TimeoutDisposition::None,
        )
        .unwrap();
        assert_eq!(
            SemanticSnapshot::try_new(
                root,
                TournamentStanding::MatchesActive {
                    candidate: None,
                    joins: JoinDisposition::Open,
                },
                digest(2),
                LocalCommitmentStanding::Engaged(engagement),
                None,
                None,
            ),
            Err(DomainError::EngagementCommitmentMismatch)
        );

        let elimination = EliminationRecord::try_new(
            digest(1),
            match_id(),
            EliminationReason::Timeout,
            Some(MatchSide::Two),
        )
        .unwrap();
        assert_eq!(
            SemanticSnapshot::try_new(
                root,
                TournamentStanding::MatchesActive {
                    candidate: None,
                    joins: JoinDisposition::Open,
                },
                digest(2),
                LocalCommitmentStanding::Eliminated(elimination),
                None,
                None,
            ),
            Err(DomainError::EliminationCommitmentMismatch)
        );
    }

    #[test]
    fn snapshot_validates_recursive_child_seam() {
        let parent_descriptor = descriptor(address(1), 0, 2, digest(9), 0);
        let child_descriptor = descriptor(address(2), 1, 2, digest(10), 24);
        let parent_link =
            ParentLink::try_new(address(1), match_id(), digest(1)).expect("commitment one");
        let child = SemanticSnapshot::try_new(
            child_descriptor,
            TournamentStanding::AwaitingClosure {
                candidate: Some(digest(20)),
            },
            digest(20),
            LocalCommitmentStanding::Candidate,
            Some(parent_link),
            None,
        )
        .unwrap();

        let awaiting = AwaitingChildMatch::try_new(divergence(), address(2)).unwrap();
        let engagement = Engagement::try_new(
            digest(1),
            match_id(),
            LiveMatchState::AwaitingChild(awaiting),
            TimeoutDisposition::None,
        )
        .unwrap();
        let parent = SemanticSnapshot::try_new(
            parent_descriptor,
            TournamentStanding::MatchesActive {
                candidate: None,
                joins: JoinDisposition::Closed,
            },
            digest(1),
            LocalCommitmentStanding::Engaged(engagement),
            None,
            Some(child),
        )
        .unwrap();

        assert_eq!(
            parent.child().unwrap().descriptor().base_cycle(),
            U256::from(24)
        );
        assert_eq!(
            parent.child().unwrap().parent().unwrap().parent_match(),
            match_id()
        );
    }

    #[test]
    fn snapshot_rejects_inner_winner_outside_parent_match() {
        let parent_link =
            ParentLink::try_new(address(1), match_id(), digest(1)).expect("commitment one");
        assert_eq!(
            SemanticSnapshot::try_new(
                descriptor(address(2), 1, 2, digest(10), 24),
                TournamentStanding::InnerWinner(InnerWinner::new(digest(99), digest(20))),
                digest(20),
                LocalCommitmentStanding::Candidate,
                Some(parent_link),
                None,
            ),
            Err(DomainError::InnerWinnerOutsideParentMatch)
        );
    }

    #[test]
    fn elimination_record_consumes_survivor_evidence() {
        assert_eq!(
            EliminationRecord::try_new(
                digest(1),
                match_id(),
                EliminationReason::Timeout,
                Some(MatchSide::One),
            ),
            Err(DomainError::SurvivorMarkedEliminated)
        );
        assert_eq!(
            EliminationRecord::try_new(digest(1), match_id(), EliminationReason::Step, None,),
            Err(DomainError::StepDeletionMissingSurvivor)
        );

        let step_loser = EliminationRecord::try_new(
            digest(1),
            match_id(),
            EliminationReason::Step,
            Some(MatchSide::Two),
        )
        .unwrap();
        assert_eq!(step_loser.local_side(), MatchSide::One);
        assert_eq!(step_loser.survivor(), Some(MatchSide::Two));

        assert!(
            EliminationRecord::try_new(digest(1), match_id(), EliminationReason::Timeout, None,)
                .is_ok()
        );
    }

    #[test]
    fn timeout_shape_rejects_impossible_phase_combinations() {
        let bisecting = BisectingMatch::try_new(
            digest(3),
            WaitingChildren::new(digest(4), digest(5)),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            4,
            MatchSide::One,
        )
        .unwrap();
        assert_eq!(
            LiveMatch::try_new(
                LiveMatchState::Bisecting(bisecting),
                TimeoutDisposition::OneWins {
                    deferred_charge: BlockDuration::ZERO,
                },
            ),
            Err(DomainError::ActiveTimeoutWinnerIsResponder)
        );
        assert!(
            LiveMatch::try_new(
                LiveMatchState::Bisecting(bisecting),
                TimeoutDisposition::TwoWins {
                    deferred_charge: BlockDuration::from_blocks(7),
                },
            )
            .is_ok()
        );

        let sealed = LiveMatchState::SealedLeaf(SealedLeafMatch::new(divergence()));
        assert_eq!(
            LiveMatch::try_new(
                sealed,
                TimeoutDisposition::OneWins {
                    deferred_charge: BlockDuration::from_blocks(1),
                },
            ),
            Err(DomainError::SealedLeafDeferredCharge)
        );
        assert!(
            LiveMatch::try_new(
                sealed,
                TimeoutDisposition::OneWins {
                    deferred_charge: BlockDuration::ZERO,
                },
            )
            .is_ok()
        );
    }

    #[test]
    fn snapshot_validates_match_height_responder_position_and_cycle() {
        let leaf = descriptor(address(1), 0, 1, digest(9), 0);
        let waiting = WaitingChildren::new(digest(4), digest(5));

        let too_tall = BisectingMatch::try_new(
            digest(3),
            waiting,
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            5,
            MatchSide::One,
        )
        .unwrap();
        assert_eq!(
            snapshot_with_engagement(
                leaf,
                LiveMatchState::Bisecting(too_tall),
                TimeoutDisposition::None,
            ),
            Err(DomainError::MatchHeightOutOfRange)
        );

        let wrong_responder = BisectingMatch::try_new(
            digest(3),
            waiting,
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            3,
            MatchSide::One,
        )
        .unwrap();
        assert_eq!(
            snapshot_with_engagement(
                leaf,
                LiveMatchState::Bisecting(wrong_responder),
                TimeoutDisposition::None,
            ),
            Err(DomainError::ResponderParityMismatch)
        );

        let misaligned = BisectingMatch::try_new(
            digest(3),
            waiting,
            MatchCoordinate::new(U256::from(1), U256::from(8)),
            2,
            MatchSide::One,
        )
        .unwrap();
        assert_eq!(
            snapshot_with_engagement(
                leaf,
                LiveMatchState::Bisecting(misaligned),
                TimeoutDisposition::None,
            ),
            Err(DomainError::MatchPositionMisaligned)
        );

        let out_of_range = SealedDivergence::new(
            digest(10),
            MatchCoordinate::new(U256::from(16), U256::from(128)),
            digest(11),
            digest(12),
        );
        assert_eq!(
            snapshot_with_engagement(
                leaf,
                LiveMatchState::SealedLeaf(SealedLeafMatch::new(out_of_range)),
                TimeoutDisposition::None,
            ),
            Err(DomainError::MatchPositionOutOfRange)
        );

        let wrong_cycle = SealedDivergence::new(
            digest(10),
            MatchCoordinate::new(U256::from(3), U256::from(25)),
            digest(11),
            digest(12),
        );
        assert_eq!(
            snapshot_with_engagement(
                leaf,
                LiveMatchState::SealedLeaf(SealedLeafMatch::new(wrong_cycle)),
                TimeoutDisposition::None,
            ),
            Err(DomainError::MatchCycleMismatch)
        );
    }

    #[test]
    fn recursive_child_rejects_wrong_initial_hash_and_base_cycle() {
        let parent_descriptor = descriptor(address(1), 0, 2, digest(9), 0);
        let parent_link =
            ParentLink::try_new(address(1), match_id(), digest(1)).expect("commitment one");
        let awaiting =
            AwaitingChildMatch::try_new(divergence(), address(2)).expect("nonzero child");
        let engagement = Engagement::try_new(
            digest(1),
            match_id(),
            LiveMatchState::AwaitingChild(awaiting),
            TimeoutDisposition::None,
        )
        .unwrap();

        for (child_descriptor, expected) in [
            (
                descriptor(address(2), 1, 2, digest(77), 24),
                DomainError::ChildInitialHashMismatch,
            ),
            (
                descriptor(address(2), 1, 2, digest(10), 25),
                DomainError::ChildBaseCycleMismatch,
            ),
        ] {
            let child = SemanticSnapshot::try_new(
                child_descriptor,
                TournamentStanding::AwaitingClosure {
                    candidate: Some(digest(20)),
                },
                digest(20),
                LocalCommitmentStanding::Candidate,
                Some(parent_link),
                None,
            )
            .unwrap();
            assert_eq!(
                SemanticSnapshot::try_new(
                    parent_descriptor,
                    TournamentStanding::MatchesActive {
                        candidate: None,
                        joins: JoinDisposition::Closed,
                    },
                    digest(1),
                    LocalCommitmentStanding::Engaged(engagement),
                    None,
                    Some(child),
                ),
                Err(expected)
            );
        }
    }
}
