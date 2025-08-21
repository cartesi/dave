import {
    Card,
    Group,
    Stack,
    useMantineTheme,
    type CardProps,
} from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import type { Match } from "../types";
import { ClaimText } from "./ClaimText";

export interface MatchLoserCardProps extends CardProps {
    /**
     * The match to display.
     */
    match: Match;

    /**
     * Simulated current time.
     * When not provided, the card is shown as is.
     * When provided, the match timestamps are used to filter out events that did not happen yet based on the simulated time.
     */
    now?: number;

    /**
     * Handler for the match card click event. When not provided, the match card is not clickable.
     */
    onClick?: () => void;
}

export const MatchLoserCard: FC<MatchLoserCardProps> = ({
    match,
    now,
    onClick,
    ...cardProps
}) => {
    const { claim1, claim2, winner } = match;
    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    if (now && match.timestamp > now) {
        return;
    }

    const loser = winner === 1 ? claim2 : winner === 2 ? claim1 : undefined;
    if (!loser) {
        return;
    }

    return (
        <Card
            withBorder
            shadow="sm"
            radius="lg"
            {...cardProps}
            onClick={onClick}
        >
            <Stack gap={0}>
                <Group gap="xs" wrap="nowrap">
                    <TbTrophyFilled size={24} color={gold} opacity={0} />
                    <ClaimText
                        claim={loser}
                        style={{ textDecoration: "line-through" }}
                    />
                </Group>
            </Stack>
        </Card>
    );
};
