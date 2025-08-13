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
    now?: number;
}

export const MatchCard: FC<MatchCardProps> = ({ match, now, ...cardProps }) => {
    const { claim1, claim2, winner } = match;
    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    if (now) {
        if (match.claim2Timestamp) {
            if (match.claim1Timestamp > now && match.claim2Timestamp > now) {
                // both claims are in the future compared to simulated now, don't show anything
                return;
            }
        } else if (match.claim1Timestamp > now) {
            // claim is in the future compared to simulated now, don't show anything
            return;
        }
    }

    const showClaim1 = !now || match.claim1Timestamp <= now;
    const showClaim2 =
        match.claim2 &&
        match.claim2Timestamp &&
        (!now || match.claim2Timestamp <= now);
    const showWinner =
        winner &&
        (!now || (match.winnerTimestamp && match.winnerTimestamp <= now));

    return (
        <Card withBorder shadow="sm" radius="lg" {...cardProps}>
            <Overlay
                bg={gold}
                opacity={showWinner && winner === 1 ? 0.1 : 0}
                style={{
                    height: claim2 ? "50%" : "100%",
                    pointerEvents: "none",
                }}
            />
            <Overlay
                bg={gold}
                opacity={showWinner && winner === 2 ? 0.1 : 0}
                style={{ top: "50%", height: "50%", pointerEvents: "none" }}
            />
            <Stack gap={0}>
                {showClaim1 && (
                    <Group gap="xs" wrap="nowrap">
                        <TbTrophyFilled
                            size={24}
                            color={gold}
                            opacity={showWinner && winner === 1 ? 1 : 0}
                        />
                        <ClaimCard
                            claim={claim1}
                            c={showWinner && winner === 1 ? gold : undefined}
                            fw={showWinner && winner === 1 ? 700 : undefined}
                            style={{
                                textDecoration:
                                    winner === 2 && showWinner
                                        ? "line-through"
                                        : undefined,
                            }}
                        />
                    </Group>
                )}
                {showClaim1 && showClaim2 && (
                    <Text style={{ textAlign: "center" }}>vs</Text>
                )}
                {showClaim2 && (
                    <Group gap="xs" wrap="nowrap">
                        {claim2 && (
                            <TbTrophyFilled
                                size={24}
                                color={gold}
                                opacity={showWinner && winner === 2 ? 1 : 0}
                            />
                        )}
                        {claim2 && (
                            <ClaimCard
                                claim={claim2}
                                c={
                                    showWinner && winner === 2
                                        ? gold
                                        : undefined
                                }
                                fw={
                                    showWinner && winner === 2 ? 700 : undefined
                                }
                                style={{
                                    textDecoration:
                                        winner === 1 && showWinner
                                            ? "line-through"
                                            : undefined,
                                }}
                            />
                        )}
                    </Group>
                )}
            </Stack>
        </Card>
    );
};
