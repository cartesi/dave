import { Button, Group, Paper, Stack, Text, Timeline } from "@mantine/core";
import humanizeDuration from "humanize-duration";
import { useMemo, type FC } from "react";
import { TbTrendingDown } from "react-icons/tb";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import type { CycleRange } from "../types";

export interface SubTournamentItemProps {
    /**
     * Level of the sub tournament
     */
    level: "middle" | "bottom";

    /**
     * Current timestamp
     */
    now?: number;

    /**
     * Cycle range
     */
    range: CycleRange;

    /**
     * Timestamp
     */
    timestamp: number;
}

export const SubTournamentItem: FC<SubTournamentItemProps> = (props) => {
    const { level, range, timestamp } = props;

    // allow now to be defined outside, default to Date.now
    const now = useMemo(
        () => props.now ?? Math.floor(Date.now() / 1000),
        [props.now],
    );

    const formatTime = (timestamp: number) => {
        return `${humanizeDuration((now - timestamp) * 1000, { units: ["h", "m", "s"] })} ago`;
    };

    return (
        <Timeline.Item>
            <Stack gap={3}>
                <Paper withBorder radius="lg" p={16} bg="gray.0">
                    <Group justify="space-between">
                        <Stack gap="xs">
                            <CycleRangeFormatted
                                size="xs"
                                c="dimmed"
                                cycleRange={range}
                            />
                        </Stack>
                        <Button rightSection={<TbTrendingDown />}>
                            {level}
                        </Button>
                    </Group>
                </Paper>
                <Text size="xs" c="dimmed">
                    {formatTime(timestamp)}
                </Text>
            </Stack>
        </Timeline.Item>
    );
};
