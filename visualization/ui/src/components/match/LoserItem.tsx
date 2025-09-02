import { Group, useMantineTheme } from "@mantine/core";
import { type FC } from "react";
import { TbCircleXFilled } from "react-icons/tb";
import { ClaimText } from "../tournament/ClaimText";
import type { Claim } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";

export interface LoserItemProps {
    /**
     * Claim that lost
     */
    claim: Claim;

    /**
     * Current timestamp
     */
    now: number;
}

export const LoserItem: FC<LoserItemProps> = (props) => {
    const { claim, now } = props;

    const theme = useMantineTheme();
    const dimmed = theme.colors.gray[5];

    return (
        <ClaimTimelineItem claim={claim} now={now}>
            <Group gap="xs">
                <TbCircleXFilled size={24} color={dimmed} />
                <ClaimText claim={claim} withIcon={false} />
            </Group>
        </ClaimTimelineItem>
    );
};
