local Fold = require "player.fold"
local Test = require "tests.testlib"
local bint = require "utils.bint" (256)

local E = Fold.Event

local function match_hash(match_id)
    return match_id.commitment_one .. ":" .. match_id.commitment_two
end

local function new_fold()
    return Fold.new("root", { match_id_hash = match_hash })
end

local function event(tournament, block, kind)
    return Fold.event(tournament, block, kind)
end

local function join(fold, tournament, block, root)
    fold:apply(event(
        tournament,
        block,
        E.commitment_joined(root, root .. "-final")
    ))
end

local function matched_fold()
    local fold = new_fold()
    join(fold, "root", 1, "a")
    join(fold, "root", 2, "b")
    fold:apply(event(
        "root",
        3,
        E.match_created("a", "b", "left", "a:b", 30)
    ))
    return fold
end

return {
    Test.case("six-event fold derives nested dispute structure", function()
        local fold = new_fold()
        local script = {
            event("root", 1, E.commitment_joined("a", "a-final")),
            event("root", 2, E.commitment_joined("b", "b-final")),
            event("root", 3, E.match_created(
                "a", "b", "b-left", "a:b", 30
            )),
            event("root", 4, E.match_advanced(
                "a:b", "other", "left", 0, 40
            )),
            event("root", 5, E.new_inner_tournament("a:b", "child")),
            event("child", 6, E.commitment_joined("c", "c-final")),
            event("child", 7, E.commitment_joined("d", "d-final")),
            event("child", 8, E.match_created(
                "c", "d", "d-left", "c:d", 50
            )),
            event("child", 9, E.leaf_match_sealed("c:d", 60)),
            event("child", 10, E.match_deleted(
                "c:d",
                Fold.MatchDeletionReason.STEP,
                Fold.WinnerCommitment.ONE
            )),
            event("root", 11, E.match_deleted(
                "a:b",
                Fold.MatchDeletionReason.CHILD_TOURNAMENT,
                Fold.WinnerCommitment.ONE
            )),
        }
        fold:apply_all(script)

        local addresses = fold:addresses()
        Test.equal(#addresses, 2)
        Test.equal(addresses[1], "root")
        Test.equal(addresses[2], "child")

        local root_match = fold:match_by_id_hash("root", "a:b")
        Test.equal(root_match.advances, 1)
        Test.equal(root_match.last_other_parent, "other")
        Test.equal(root_match.last_left_node, "left")
        Test.equal(root_match.inner_tournament, "child")
        Test.equal(root_match.eliminable_at, nil)
        Test.equal(
            root_match.deleted.reason,
            Fold.MatchDeletionReason.CHILD_TOURNAMENT
        )

        local child = fold:tournament("child")
        Test.equal(child.level, 1)
        Test.equal(child.parent.tournament, "root")
        Test.equal(child.parent.match_id_hash, "a:b")
        Test.equal(fold:candidate("root"), "a")
        Test.equal(fold:candidate("child"), "c")
        Test.equal(#fold:live_matches("root"), 0)
    end),

    Test.case("fold clones the mutable position breadcrumb", function()
        local fold = matched_fold()
        local position = bint(7)
        fold:apply(event(
            "root",
            4,
            E.match_advanced("a:b", "other", "left", position, 40)
        ))

        -- Mutating the retained event value must not reach the fold.
        position[1] = 99
        local read = fold:match_by_id_hash("root", "a:b")
        Test.truthy(bint.eq(read.last_segment_start_position, 7),
            "ingestion must clone the event's position")

        -- Mutating an accessor result must not reach the fold either.
        read.last_segment_start_position[1] = 42
        Test.truthy(bint.eq(
            fold:match_by_id_hash("root", "a:b").last_segment_start_position,
            7
        ), "copies must not alias fold storage")
    end),

    Test.case("fold rejects malformed event streams", function()
        local rows = {
            {
                message = "joined twice",
                run = function()
                    local fold = new_fold()
                    join(fold, "root", 1, "a")
                    join(fold, "root", 2, "a")
                end,
            },
            {
                message = "unjoined commitment two",
                run = function()
                    local fold = new_fold()
                    join(fold, "root", 1, "a")
                    fold:apply(event(
                        "root",
                        2,
                        E.match_created("a", "b", "left", "a:b", 30)
                    ))
                end,
            },
            {
                message = "hash disagrees",
                run = function()
                    local fold = new_fold()
                    join(fold, "root", 1, "a")
                    join(fold, "root", 2, "b")
                    fold:apply(event(
                        "root",
                        3,
                        E.match_created("a", "b", "left", "wrong", 30)
                    ))
                end,
            },
            {
                message = "unknown match",
                run = function()
                    new_fold():apply(event(
                        "root",
                        1,
                        E.match_advanced("missing", "other", "left", 0, 30)
                    ))
                end,
            },
            {
                message = "deleted match",
                run = function()
                    local fold = new_fold()
                    join(fold, "root", 1, "a")
                    join(fold, "root", 2, "b")
                    fold:apply(event(
                        "root",
                        3,
                        E.match_created("a", "b", "left", "a:b", 30)
                    ))
                    fold:apply(event("root", 4, E.match_deleted(
                        "a:b",
                        Fold.MatchDeletionReason.TIMEOUT,
                        Fold.WinnerCommitment.NEITHER
                    )))
                    fold:apply(event(
                        "root",
                        5,
                        E.match_advanced("a:b", "other", "left", 0, 30)
                    ))
                end,
            },
            {
                message = "undiscovered tournament",
                run = function()
                    new_fold():apply(event(
                        "child",
                        1,
                        E.commitment_joined("a", "final")
                    ))
                end,
            },
            {
                message = "not in block order",
                run = function()
                    local fold = new_fold()
                    join(fold, "root", 2, "a")
                    join(fold, "root", 1, "b")
                end,
            },
            {
                message = "step deletion must record",
                run = function()
                    matched_fold():apply(event(
                        "root",
                        4,
                        E.match_deleted(
                            "a:b",
                            Fold.MatchDeletionReason.STEP,
                            Fold.WinnerCommitment.NEITHER
                        )
                    ))
                end,
            },
            {
                message = "exceeds uint64",
                run = function()
                    E.match_created(
                        "a",
                        "b",
                        "left",
                        "a:b",
                        "0x10000000000000000"
                    )
                end,
            },
        }
        for _, row in ipairs(rows) do
            Test.error_like(row.message, row.run)
        end
    end),

    Test.case("deletion reason and winner matrix matches Solidity", function()
        local legal = {
            {
                Fold.MatchDeletionReason.STEP,
                Fold.WinnerCommitment.ONE,
            },
            {
                Fold.MatchDeletionReason.STEP,
                Fold.WinnerCommitment.TWO,
            },
            {
                Fold.MatchDeletionReason.TIMEOUT,
                Fold.WinnerCommitment.NEITHER,
            },
            {
                Fold.MatchDeletionReason.TIMEOUT,
                Fold.WinnerCommitment.ONE,
            },
            {
                Fold.MatchDeletionReason.TIMEOUT,
                Fold.WinnerCommitment.TWO,
            },
            {
                Fold.MatchDeletionReason.CHILD_TOURNAMENT,
                Fold.WinnerCommitment.NEITHER,
            },
            {
                Fold.MatchDeletionReason.CHILD_TOURNAMENT,
                Fold.WinnerCommitment.ONE,
            },
            {
                Fold.MatchDeletionReason.CHILD_TOURNAMENT,
                Fold.WinnerCommitment.TWO,
            },
        }

        for _, shape in ipairs(legal) do
            local fold = matched_fold()
            fold:apply(event("root", 4, E.match_deleted(
                "a:b",
                shape[1],
                shape[2]
            )))
            local deleted = fold:match_by_id_hash("root", "a:b").deleted
            Test.equal(deleted.reason, shape[1])
            Test.equal(deleted.winner, shape[2])
        end
    end),

    Test.case("candidate follows winner, re-pairing, and double elimination", function()
        local fold = new_fold()
        join(fold, "root", 1, "a")
        join(fold, "root", 2, "b")
        fold:apply(event(
            "root",
            3,
            E.match_created("a", "b", "left", "a:b", 30)
        ))
        fold:apply(event("root", 4, E.match_deleted(
            "a:b",
            Fold.MatchDeletionReason.STEP,
            Fold.WinnerCommitment.ONE
        )))
        Test.equal(fold:candidate("root"), "a")
        Test.equal(
            fold:commitment_status("root", "b")._tag,
            Fold.CommitmentStatus.ELIMINATED
        )

        join(fold, "root", 5, "c")
        fold:apply(event(
            "root",
            6,
            E.match_created("a", "c", "left", "a:c", 30)
        ))
        Test.equal(fold:candidate("root"), nil)
        Test.equal(
            fold:commitment_status("root", "a")._tag,
            Fold.CommitmentStatus.ENGAGED
        )

        fold:apply(event("root", 7, E.match_deleted(
            "a:c",
            Fold.MatchDeletionReason.TIMEOUT,
            Fold.WinnerCommitment.NEITHER
        )))
        Test.equal(fold:candidate("root"), nil)
        Test.equal(
            fold:commitment_status("root", "a")._tag,
            Fold.CommitmentStatus.ELIMINATED
        )
        Test.equal(
            fold:commitment_status("root", "c")._tag,
            Fold.CommitmentStatus.ELIMINATED
        )
    end),

    Test.case("match schedule follows the latest structural event", function()
        local fold = matched_fold()
        Test.equal(tostring(
            fold:match_by_id_hash("root", "a:b").eliminable_at
        ), "30")

        fold:apply(event(
            "root",
            4,
            E.match_advanced("a:b", "other", "left", 0, 40)
        ))
        Test.equal(tostring(
            fold:match_by_id_hash("root", "a:b").eliminable_at
        ), "40")

        fold:apply(event(
            "root",
            5,
            E.leaf_match_sealed("a:b", "18446744073709551615")
        ))
        Test.equal(tostring(
            fold:match_by_id_hash("root", "a:b").eliminable_at
        ), "18446744073709551615")

        fold:apply(event("root", 6, E.match_deleted(
            "a:b",
            Fold.MatchDeletionReason.TIMEOUT,
            Fold.WinnerCommitment.NEITHER
        )))
        Test.equal(
            fold:match_by_id_hash("root", "a:b").eliminable_at,
            nil
        )

        fold = matched_fold()
        fold:apply(event(
            "root",
            4,
            E.new_inner_tournament("a:b", "child")
        ))
        Test.equal(
            fold:match_by_id_hash("root", "a:b").eliminable_at,
            nil
        )
    end),

    Test.case("fold accessors do not expose mutable index records", function()
        local fold = matched_fold()
        fold:apply(event(
            "root",
            4,
            E.new_inner_tournament("a:b", "child")
        ))

        local root = fold:tournament("root")
        root.commitments.a.final_state = "mutated-final"
        root.commitment_order[1] = "mutated-order"
        root.matches[1].id.commitment_one = "mutated-id"
        root.matches[1].advances = 99
        root.match_index["a:b"] = 99

        local child = fold:tournament("child")
        child.parent.tournament = "mutated-parent"

        local all = fold:tournaments()
        all[1].matches[1].last_left_node = "mutated-left"

        local by_hash = fold:match_by_id_hash("root", "a:b")
        by_hash.inner_tournament = "mutated-child"

        local live = fold:live_matches("root")
        live[1].last_other_parent = "mutated-parent"

        local status = fold:commitment_status("root", "a")
        status.match.id.commitment_two = "mutated-opponent"

        root = fold:tournament("root")
        Test.equal(root.commitments.a.final_state, "a-final")
        Test.equal(root.commitment_order[1], "a")
        Test.equal(root.matches[1].id.commitment_one, "a")
        Test.equal(root.matches[1].id.commitment_two, "b")
        Test.equal(root.matches[1].advances, 0)
        Test.equal(root.matches[1].last_left_node, "left")
        Test.equal(root.matches[1].last_other_parent, "a")
        Test.equal(root.matches[1].inner_tournament, "child")
        Test.equal(root.match_index["a:b"], 1)
        Test.equal(
            fold:tournament("child").parent.tournament,
            "root"
        )
    end),
}
