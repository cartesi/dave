import { Flex } from "@mantine/core";
import type { FC } from "react";
import type { Match, Round } from "../types";
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
    rounds: Round[];
}

export const TournamentTable: FC<TournamentTableProps> = ({
    hideWinners,
    now,
    onClickMatch,
    rounds,
}) => {
    return (
        <Flex gap="md">
            {rounds.map((round, index) => (
                <TournamentRound
                    index={index}
                    matches={round.matches}
                    now={now}
                    onClickMatch={onClickMatch}
                    hideWinners={hideWinners}
                />
            ))}
        </Flex>
    );
};
