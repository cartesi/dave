import { Group, Paper, useMantineTheme } from "@mantine/core";
import { type FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import type { Hex } from "viem";
import { ClaimText } from "../tournament/ClaimText";
import type { Claim } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";

export interface WinnerItemProps {
    /**
     * Winner claim
     */
    claim: Claim;

    /**
     * Current timestamp
     */
    now: number;

    /**
     * Proof of the winner
     */
    proof: Hex;

    /**
     * Timestamp
     */
    timestamp: number;
}

export const WinnerItem: FC<WinnerItemProps> = (props) => {
    const { claim, now, proof, timestamp } = props;

    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    return (
        <ClaimTimelineItem claim={claim} now={now} timestamp={timestamp}>
            <Paper withBorder p={16} radius="lg" bg={theme.colors.yellow[0]}>
                <Group gap="xs">
                    <TbTrophyFilled size={24} color={gold} />
                    <ClaimText claim={claim} withIcon={false} />
                </Group>
            </Paper>
        </ClaimTimelineItem>
    );
};
