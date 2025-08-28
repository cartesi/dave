import { concat, hexToNumber, keccak256, slice, type Hex } from "viem";
import type { Claim, Tournament } from "../components/types";

/**
 * Create a pseudo-random number generator from a seed
 * @param seed seed for the generator
 * @returns pseudo-random number generator
 */
export function mulberry32(seed: number) {
    return function () {
        seed |= 0;
        seed = (seed + 0x6d2b79f5) | 0;
        let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

/**
 * Return a number between 0 and 1 from a hex value.
 * @param value hex value with arbitrary length
 * @returns number between 0 and 1
 */
const hexToFraction = (value: Hex): number => {
    const l = slice(value, 0, 1);
    const n = hexToNumber(l);
    return n / 256;
};

/**
 * Generate a random winner for a match, 20% chance of undefined, 40% chance of 1, 40% chance of 2
 * @returns
 */
const randomWinner = (claim1: Claim, claim2: Claim): 1 | 2 | undefined => {
    const r = hexToFraction(keccak256(concat([claim1.hash, claim2.hash])));
    if (r < 0.2) return undefined;
    if (r < 0.6) return 1;
    return 2;
};

/**
 * Create a pseudo-random list of ranges that bisect the given range n times
 * @param range range to bisect
 * @param n number of ranges to create
 * @returns list of ranges
 */
export const randomBisections = (n: number, seed: number = 0): (0 | 1)[] => {
    // initialize the random number generator
    const rand = mulberry32(seed);

    // initialize the list of ranges
    const ranges: (0 | 1)[] = [];

    // create the ranges
    for (let i = 0; i < n; i++) {
        // choose a random direction to bisect the range
        if (rand() < 0.5) {
            ranges.push(0);
        } else {
            ranges.push(1);
        }
    }
    // remove the first range, which is the original range
    return ranges;
};

/**
 * Create matches for a tournament
 * @param tournament Tournament to create matches for
 * @param claims Claims to create matches for
 * @returns Tournament with matches
 */
export const randomMatches = (
    timestamp: number,
    tournament: Tournament,
    claims: Claim[],
): Tournament => {
    const rng = mulberry32(0);

    let claim = claims.shift();
    while (claim) {
        if (tournament.danglingClaim) {
            // create a match with the dangling claim
            const claim1 = tournament.danglingClaim;
            tournament.matches.push({
                actions: [],
                claim1,
                claim2: claim,
                parentTournament: tournament,
                timestamp,
            });
            tournament.danglingClaim = undefined;
            timestamp++; // XXX: improve this timestamp incrementation
        } else {
            // assign the claim to the dangling slot
            tournament.danglingClaim = claim;
        }

        // get pending matches (without a winner) and pick one randomlly
        const pending = tournament.matches.filter((match) => !match.winner);
        const match = pending[Math.floor(rng() * pending.length)];
        if (match) {
            // resolve a winner randomly
            const winner = randomWinner(match.claim1, match.claim2);
            if (winner) {
                // assign the winner, and put the claim back to the list
                match.winner = winner;
                match.winnerTimestamp = timestamp;
                timestamp++; // XXX: improve this timestamp incrementation
                const winnerClaim = winner === 1 ? match.claim1 : match.claim2;
                claims.unshift(winnerClaim);
            }
        }

        claim = claims.shift();
    }

    // define tournament winner
    const pending = tournament.matches.filter((match) => !match.winner);
    if (pending.length === 0) {
        // all matches are resolved, the winner is the last surviving claim
        const lastMatch = tournament.matches[tournament.matches.length - 1];
        tournament.winner =
            lastMatch.winner === 1 ? lastMatch.claim1 : lastMatch.claim2;
    }

    return tournament;
};
