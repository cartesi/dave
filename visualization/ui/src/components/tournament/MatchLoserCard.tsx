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
import { ClaimCard } from "./ClaimCard";

export interface MatchLoserCardProps extends CardProps {
    match: Match;
    now?: number;
}

export const MatchLoserCard: FC<MatchLoserCardProps> = ({
    match,
    now,
    ...cardProps
}) => {
    const { claim1, claim2, winner } = match;
    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    if (now) {
        if (
            winner === 1 &&
            match.claim2Timestamp &&
            match.claim2Timestamp > now
        ) {
            return;
        }
        if (winner === 2 && match.claim1Timestamp > now) {
            return;
        }
    }

    const loser = winner === 1 ? claim2 : winner === 2 ? claim1 : undefined;
    if (!loser) {
        return;
    }

    return (
        <Card withBorder shadow="sm" radius="lg" {...cardProps}>
            <Stack gap={0}>
                <Group gap="xs" wrap="nowrap">
                    <TbTrophyFilled size={24} color={gold} opacity={0} />
                    <ClaimCard
                        claim={loser}
                        style={{ textDecoration: "line-through" }}
                    />
                </Group>
            </Stack>
        </Card>
    );
};
