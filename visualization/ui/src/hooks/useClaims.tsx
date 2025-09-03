import { useEffect, useState } from "react";
import type { Address, Hash } from "viem";

/**
 * URL to the data file containing the status of the current sealed epoch
 */
const statusUrl =
    "https://github.com/cartesi/dave-monitoring/raw/refs/heads/main/data/canSettle.json";

/**
 * URL to the data file containing tournaments and claims
 */
const dataUrl =
    "https://github.com/cartesi/dave-monitoring/raw/refs/heads/main/data/data.json";

type Status = {
    isFinished: boolean;
    epochNumber: string; // number
    winnerCommitment: Hash;
    lastCanSettleTimestamp: number;
    currentSealedEpoch: {
        epochNumber: string; // number
        inputIndexLowerBound: string; // number
        inputIndexUpperBound: string; // number
        tournament: Address;
        createdAt: number;
    };
};

type Tournament = {
    claims: Record<
        Hash,
        {
            tx: Hash;
            blockNumber: string; // number
            timestamp: string; // number
        }
    >;
    address: Address;
};

type Data = {
    lastProcessedBlock: string; // number
    tournaments: Record<Address, Tournament>;
    lastTimestamp: string; // number
};

const getClaims = async (): Promise<Hash[] | undefined> => {
    let res = await fetch(`https://corsproxy.io/?url=${statusUrl}`);
    if (res.ok) {
        const status = (await res.json()) as Status;
        console.log(status);
        const tournamentAddress = status?.currentSealedEpoch?.tournament;
        if (tournamentAddress) {
            res = await fetch(`https://corsproxy.io/?url=${dataUrl}`);
            if (res.ok) {
                const data = (await res.json()) as Data;
                const tournament =
                    data.tournaments[
                        tournamentAddress.toLowerCase() as Address
                    ];
                if (tournament) {
                    return Object.keys(tournament.claims).map(
                        (hash) => hash as Hash,
                    );
                }
            }
        }
    }
    return;
};

export const useClaims = () => {
    const [claims, setClaims] = useState<Hash[]>();
    const [error, setError] = useState<string>();
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        setError(undefined);
        setLoading(true);
        getClaims()
            .then((claims) => {
                setClaims(claims);
                setLoading(false);
                setError(undefined);
            })
            .catch((error) => {
                setClaims(undefined);
                setLoading(false);
                setError(error.message);
            });
    }, []);

    return { claims, error, loading };
};
