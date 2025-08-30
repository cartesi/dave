import {
    Avatar,
    Button,
    Group,
    Paper,
    Stack,
    Text,
    Timeline,
} from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import humanizeDuration from "humanize-duration";
import { useMemo, type FC } from "react";
import { TbTrendingDown } from "react-icons/tb";
import { slice, type Hash } from "viem";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import type { Claim, CycleRange } from "../types";

export interface SubTournamentItemProps {
    /**
     * Claim that took action.
     */
    claim: Claim;

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

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const SubTournamentItem: FC<SubTournamentItemProps> = (props) => {
    const { claim, level, range, timestamp } = props;

    // allow now to be defined outside, default to Date.now
    const now = useMemo(
        () => props.now ?? Math.floor(Date.now() / 1000),
        [props.now],
    );

    const formatTime = (timestamp: number) => {
        return `${humanizeDuration((now - timestamp) * 1000, { units: ["h", "m", "s"] })} ago`;
    };

    return (
        <Timeline.Item
            bullet={<Avatar src={buildDataUrl(claim.hash)} size={24} />}
        >
            <Stack gap={3}>
                <Paper withBorder radius="lg" p={16} bg="gray.0">
                    <Group justify="space-between">
                        <Stack gap="xs">
                            <CycleRangeFormatted
                                size="xs"
                                c="dimmed"
                                range={range}
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
