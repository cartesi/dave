import {
    Group,
    Paper,
    Stack,
    Text,
    Timeline,
    useMantineTheme,
} from "@mantine/core";
import humanizeDuration from "humanize-duration";
import { useMemo, type FC } from "react";
import { TbClockCancel, TbSwordOff } from "react-icons/tb";
import { HashAvatar } from "../HashAvatar";
import type { Claim } from "../types";

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
    now?: number;

    /**
     * Timestamp
     */
    timestamp: number;
}

export const EliminationTimeoutItem: FC<EliminationTimeoutItemProps> = (
    props,
) => {
    const { claim1, claim2, timestamp } = props;

    // allow now to be defined outside, default to Date.now
    const now = useMemo(
        () => props.now ?? Math.floor(Date.now() / 1000),
        [props.now],
    );

    const theme = useMantineTheme();
    const dimmed = theme.colors.gray[5];

    const formatTime = (timestamp: number) => {
        return `${humanizeDuration((now - timestamp) * 1000, { units: ["h", "m", "s"] })} ago`;
    };

    return (
        <>
            <Timeline.Item bullet={<HashAvatar hash={claim1.hash} size={24} />}>
                <Stack gap={3}>
                    <Group>
                        <TbClockCancel size={24} color={dimmed} />
                        <Text c="dimmed">no action taken</Text>
                    </Group>
                    <Text size="xs" c="dimmed">
                        &nbsp;
                    </Text>
                </Stack>
            </Timeline.Item>
            <Timeline.Item bullet={<HashAvatar hash={claim2.hash} size={24} />}>
                <Stack gap={3}>
                    <Group>
                        <TbClockCancel size={24} color={dimmed} />
                        <Text c="dimmed">no action taken</Text>
                    </Group>
                    <Text size="xs" c="dimmed">
                        &nbsp;
                    </Text>
                </Stack>
            </Timeline.Item>
            <Timeline.Item>
                <Stack gap={3}>
                    <Paper
                        withBorder
                        p={16}
                        radius="lg"
                        bg={theme.colors.gray[0]}
                    >
                        <Group gap="xs">
                            <TbSwordOff size={24} />
                            <Text>both claims eliminated</Text>
                        </Group>
                    </Paper>
                    <Text size="xs" c="dimmed">
                        {formatTime(timestamp)}
                    </Text>
                </Stack>
            </Timeline.Item>
        </>
    );
};
