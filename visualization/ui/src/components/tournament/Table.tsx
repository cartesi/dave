import { Flex } from "@mantine/core";
import type { FC } from "react";
import type { Round } from "../types";
import { TournamentRound } from "./Round";

export interface TournamentTableProps {
    rounds: Round[];
}

export const TournamentTable: FC<TournamentTableProps> = ({ rounds }) => {
    return (
        <Flex gap="md">
            {rounds.map((round, index) => (
                <TournamentRound index={index} matches={round.matches} />
            ))}
        </Flex>
    );
};
