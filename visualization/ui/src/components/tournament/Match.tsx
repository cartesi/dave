import { Card, Stack, Text, type CardProps } from "@mantine/core";
import type { FC } from "react";
import type { Match } from "../types";
import { ClaimCard } from "./Claim";

export interface MatchCardProps extends CardProps {
    match: Match;
}

export const MatchCard: FC<MatchCardProps> = ({ match, ...cardProps }) => {
    const { claim1, claim2, winner } = match;
    const c1Color = winner === 1 ? "green" : winner === 2 ? "red" : undefined;
    const c2Color = winner === 2 ? "green" : winner === 1 ? "red" : undefined;
    const c1fw = winner === 1 ? 700 : undefined;
    const c2fw = winner === 2 ? 700 : undefined;
    return (
        <Card withBorder shadow="sm" radius="lg" {...cardProps}>
            <Stack gap={0}>
                <ClaimCard claim={claim1} c={c1Color} fw={c1fw} />
                {claim2 && <Text style={{ textAlign: "center" }}>vs</Text>}
                {claim2 && <ClaimCard claim={claim2} c={c2Color} fw={c2fw} />}
            </Stack>
        </Card>
    );
};
