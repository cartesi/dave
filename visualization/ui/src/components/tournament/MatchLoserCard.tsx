import {
    Card,
    Group,
    Stack,
    useMantineTheme,
    type CardProps,
} from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { ClaimText } from "../ClaimText";
import type { Match } from "../types";

export interface MatchLoserCardProps extends CardProps {
    /**
     * The match to display.
     */
    match: Match;

    /**
     * Handler for the match card click event. When not provided, the match card is not clickable.
     */
    onClick?: () => void;
}

export const MatchLoserCard: FC<MatchLoserCardProps> = ({
    match,
    onClick,
    ...cardProps
}) => {
    const { claim1, claim2, winner } = match;
    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

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
