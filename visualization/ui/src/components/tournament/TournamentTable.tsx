import { Flex } from "@mantine/core";
import { useMemo, type FC } from "react";
import type { Hash } from "viem";
import type { Claim, Match } from "../types";
import { TournamentRound } from "./TournamentRound";
import style from "./TournamentTable.module.css";

export interface TournamentTableProps {
    hideWinners?: boolean;

    /**
     * Simulated current time.
     * When not provided, all matches are shown.
     * When provided, the match timestamps are used to filter out events that did not happen yet based on the simulated time.
     */
    now?: number;

    /**
     * The matches to display.
     */
    matches: Match[];

    /**
     * The claim that was not matched with another claim yet.
     */
    danglingClaim?: Claim;
}

function lazyArray<T>(factory: () => T): T[] {
    return new Proxy([] as T[], {
        get(target, prop, receiver) {
            if (typeof prop === "string") {
                const index = Number(prop);
                if (!Number.isNaN(index)) {
                    if (!(prop in target)) {
                        // Lazily create the element
                        target[index] = factory();
                    }
                }
            }
            return Reflect.get(target, prop, receiver);
        },
    });
}

/**
 * Distribute matches into rounds
 * @param matches Matches to distribute
 * @returns Rounds of matches
 */
type Round = {
    matches: Match[];
    danglingClaim?: Claim;
};
const roundify = (
    matches: Match[],
    danglingClaim?: Claim,
    now?: number,
): Round[] => {
    const sets = lazyArray(() => new Set<Hash>());
    const rounds: Round[] = lazyArray(() => ({
        matches: [],
        now,
    }));
    for (const match of matches) {
        for (let i = 0; i < matches.length; i++) {
            if (
                !sets[i].has(match.claim1.hash) &&
                !sets[i].has(match.claim2.hash)
            ) {
                sets[i].add(match.claim1.hash);
                sets[i].add(match.claim2.hash);
                rounds[i].matches.push(match);
                break;
            }
        }
    }
    if (rounds.length === 0 && danglingClaim) {
        // add a round for the dangling claim
        rounds.push({ matches: [], danglingClaim });
    } else {
        // put dangling claim into last round
        rounds[rounds.length - 1].danglingClaim = danglingClaim;
    }
    return rounds;
};

export const TournamentTable: FC<TournamentTableProps> = (props) => {
    const { danglingClaim, hideWinners, now } = props;

    const rounds = useMemo(() => {
        // sort matches by timestamp
        // XXX: maybe we should assume that the matches are already sorted by timestamp?
        const matches = [...props.matches].sort(
            (a, b) => a.timestamp - b.timestamp,
        );
        return roundify(matches, danglingClaim, now);
    }, [props.matches, danglingClaim, now]);

    return (
        <Flex gap="md" className={style.container} px="xs" py="sm">
            {rounds.map((round, index) => (
                <TournamentRound
                    key={`round-${index}`}
                    index={index}
                    matches={round.matches}
                    hideWinners={hideWinners}
                    danglingClaim={round.danglingClaim}
                />
            ))}
        </Flex>
    );
};
