import { Flex } from "@mantine/core";
import { useEffect, useState, type FC } from "react";
import type { Hash } from "viem";
import type { Claim, Match } from "../types";
import { TournamentRound } from "./Round";

export interface TournamentTableProps {
    hideWinners?: boolean;

    /**
     * Simulated current time.
     * When not provided, all matches are shown.
     * When provided, the match timestamps are used to filter out events that did not happen yet based on the simulated time.
     */
    now?: number;
    onClickMatch?: (match: Match) => void;

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
const roundify = (matches: Match[]): Match[][] => {
    const sets = lazyArray(() => new Set<Hash>());
    const rounds: Match[][] = lazyArray(() => []);
    for (const match of matches) {
        for (let i = 0; i < matches.length; i++) {
            if (
                !sets[i].has(match.claim1.hash) &&
                !sets[i].has(match.claim2.hash)
            ) {
                sets[i].add(match.claim1.hash);
                sets[i].add(match.claim2.hash);
                rounds[i].push(match);
                break;
            }
        }
    }
    return rounds;
};

export const TournamentTable: FC<TournamentTableProps> = (props) => {
    const { danglingClaim, hideWinners, now, onClickMatch } = props;

    const [rounds, setRounds] = useState<Match[][]>([]);

    useEffect(() => {
        // sort matches by timestamp
        // XXX: maybe we should assume that the matches are already sorted by timestamp?
        const matches = [...props.matches].sort(
            (a, b) => a.timestamp - b.timestamp,
        );

        const rounds = roundify(matches);
        if (rounds.length === 0) {
            // create a single round with no matches (for the dangling claim if there is one)
            rounds.push([]);
        }
        setRounds(rounds);
    }, [props.matches]);

    return (
        <Flex gap="md">
            {rounds.map((matches, index) => (
                <TournamentRound
                    index={index}
                    matches={matches}
                    now={now}
                    onClickMatch={onClickMatch}
                    hideWinners={hideWinners}
                    danglingClaim={
                        index === rounds.length - 1 ? danglingClaim : undefined // dangling claim will go into last round
                    }
                />
            ))}
        </Flex>
    );
};
