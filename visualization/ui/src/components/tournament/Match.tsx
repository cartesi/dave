import { Card, Group, Stack, Text, type CardProps } from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import type { Match } from "../types";
import { ClaimCard } from "./Claim";

export interface MatchCardProps extends CardProps {
    match: Match;
}

export const MatchCard: FC<MatchCardProps> = ({ match, ...cardProps }) => {
    const { claim1, claim2, winner } = match;
    return (
        <Card withBorder shadow="sm" radius="lg" {...cardProps}>
            <Stack gap={0}>
                <Group gap="xs">
                    <TbTrophyFilled
                        size={20}
                        color="gold"
                        opacity={winner === 1 ? 1 : 0}
                    />
                    <ClaimCard
                        claim={claim1}
                        c={winner === 1 ? "gold" : undefined}
                        fw={winner === 1 ? 700 : undefined}
                    />
                </Group>
                {claim2 && <Text style={{ textAlign: "center" }}>vs</Text>}
                <Group gap="xs">
                    {claim2 && (
                        <TbTrophyFilled
                            size={20}
                            color="gold"
                            opacity={winner === 2 ? 1 : 0}
                        />
                    )}
                    {claim2 && (
                        <ClaimCard
                            claim={claim2}
                            c={winner === 2 ? "gold" : undefined}
                            fw={winner === 2 ? 700 : undefined}
                        />
                    )}
                </Group>
            </Stack>
        </Card>
    );
};
