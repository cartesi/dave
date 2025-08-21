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
import { ClaimText } from "./ClaimText";

export interface MatchCardProps extends CardProps {
    /**
     * The match to display.
     */
    match: Omit<Match, "parentTournament" | "tournament">;

    /**
     * Simulated current time.
     * When not provided, the match is shown as is.
     * When provided, the match timestamps are used to filter out events that did not happen yet based on the simulated time.
     */
    now?: number;

    /**
     * Handler for the match card click event. When not provided, the match card is not clickable.
     */
    onClick?: () => void;
}

export const MatchCard: FC<MatchCardProps> = ({
    match,
    now,
    onClick,
    ...cardProps
}) => {
    const { claim1, claim2, winner } = match;
    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    if (now && match.timestamp > now) {
        // match is in the future compared to simulated now, don't show anything
        return;
    }

    const showWinner =
        !!winner &&
        (!now || (!!match.winnerTimestamp && match.winnerTimestamp <= now));

    return (
        <Card
            component="button"
            withBorder
            shadow="sm"
            radius="lg"
            {...cardProps}
            onClick={onClick}
            style={{ cursor: onClick ? "pointer" : undefined }}
        >
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
                <Group gap="xs" wrap="nowrap">
                    <TbTrophyFilled
                        size={24}
                        color={gold}
                        opacity={showWinner && winner === 1 ? 1 : 0}
                    />
                    <ClaimText
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
                <Text style={{ textAlign: "center" }}>vs</Text>
                <Group gap="xs" wrap="nowrap">
                    <TbTrophyFilled
                        size={24}
                        color={gold}
                        opacity={showWinner && winner === 2 ? 1 : 0}
                    />
                    <ClaimText
                        claim={claim2}
                        c={showWinner && winner === 2 ? gold : undefined}
                        fw={showWinner && winner === 2 ? 700 : undefined}
                        style={{
                            textDecoration:
                                winner === 1 && showWinner
                                    ? "line-through"
                                    : undefined,
                        }}
                    />
                </Group>
            </Stack>
        </Card>
    );
};
