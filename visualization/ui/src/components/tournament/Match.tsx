import {
    Card,
    Group,
    Overlay,
    Stack,
    Text,
    useMantineTheme,
    type CardProps,
} from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import type { Match } from "../types";
import { ClaimCard } from "./Claim";

export interface MatchCardProps extends CardProps {
    match: Match;
}

export const MatchCard: FC<MatchCardProps> = ({ match, ...cardProps }) => {
    const { claim1, claim2, winner } = match;
    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];
    return (
        <Card withBorder shadow="sm" radius="lg" {...cardProps}>
            <Overlay
                bg={gold}
                opacity={winner === 1 ? 0.1 : 0}
                style={{
                    height: claim2 ? "50%" : "100%",
                    pointerEvents: "none",
                }}
            />
            <Overlay
                bg={gold}
                opacity={winner === 2 ? 0.1 : 0}
                style={{ top: "50%", height: "50%", pointerEvents: "none" }}
            />
            <Stack gap={0}>
                <Group gap="xs" wrap="nowrap">
                    <TbTrophyFilled
                        size={24}
                        color={gold}
                        opacity={winner === 1 ? 1 : 0}
                    />
                    <ClaimCard
                        claim={claim1}
                        c={winner === 1 ? gold : undefined}
                        fw={winner === 1 ? 700 : undefined}
                    />
                </Group>
                {claim2 && <Text style={{ textAlign: "center" }}>vs</Text>}
                <Group gap="xs" wrap="nowrap">
                    {claim2 && (
                        <TbTrophyFilled
                            size={24}
                            color={gold}
                            opacity={winner === 2 ? 1 : 0}
                        />
                    )}
                    {claim2 && (
                        <ClaimCard
                            claim={claim2}
                            c={winner === 2 ? gold : undefined}
                            fw={winner === 2 ? 700 : undefined}
                        />
                    )}
                </Group>
            </Stack>
        </Card>
    );
};
