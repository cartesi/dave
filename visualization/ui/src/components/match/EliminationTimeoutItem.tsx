import {
    Group,
    Paper,
    Text,
    useComputedColorScheme,
    useMantineTheme,
} from "@mantine/core";
import { type FC } from "react";
import { TbClockCancel, TbSwordOff } from "react-icons/tb";
import type { Claim } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";

interface EliminationTimeoutItemProps {
    /**
     * First claim
     */
    claim1: Claim;

    /**
     * Second claim
     */
    claim2: Claim;

    /**
     * Current timestamp
     */
    now: number;

    /**
     * Timestamp
     */
    timestamp: number;
}

export const EliminationTimeoutItem: FC<EliminationTimeoutItemProps> = (
    props,
) => {
    const { claim1, claim2, now, timestamp } = props;

    const theme = useMantineTheme();
    const scheme = useComputedColorScheme();
    const bg = scheme === "light" ? theme.colors.gray[0] : undefined;

    return (
        <>
            <ClaimTimelineItem claim={claim1} now={now}>
                <Group c="dimmed">
                    <TbClockCancel size={24} />
                    <Text c="dimmed">no action taken</Text>
                </Group>
            </ClaimTimelineItem>
            <ClaimTimelineItem claim={claim2} now={now}>
                <Group c="dimmed">
                    <TbClockCancel size={24} />
                    <Text c="dimmed">no action taken</Text>
                </Group>
            </ClaimTimelineItem>
            <ClaimTimelineItem now={now} timestamp={timestamp}>
                <Paper withBorder p={16} radius="lg" bg={bg}>
                    <Group gap="xs">
                        <TbSwordOff size={24} />
                        <Text>both claims eliminated</Text>
                    </Group>
                </Paper>
            </ClaimTimelineItem>
        </>
    );
};
