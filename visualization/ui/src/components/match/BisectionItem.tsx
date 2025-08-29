import {
    Avatar,
    Group,
    Stack,
    Text,
    Timeline,
    type TimelineItemProps,
} from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import humanizeDuration from "humanize-duration";
import { forwardRef, useMemo, type FC } from "react";
import { slice, type Hash } from "viem";
import type { Claim, CycleRange } from "../types";
import { RangeIndicator } from "./RangeIndicator";

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export interface BisectionItemProps extends TimelineItemProps {
    /**
     * Claim that performed the bisection
     */
    claim: Claim;

    /**
     * Domain of the bisection
     */
    domain: CycleRange;

    /**
     * Index of the bisection
     */
    index: number;

    /**
     * Current timestamp
     */
    now?: number;

    /**
     * Range of the bisection
     */
    range: CycleRange;

    /**
     * Timestamp of the bisection
     */
    timestamp: number;

    /**
     * Total number of bisections
     */
    total: number;
}

export const BisectionItem: FC<BisectionItemProps> = forwardRef<
    HTMLDivElement,
    BisectionItemProps
>((props, ref) => {
    const { claim, domain, index, range, timestamp, total } = props;

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
            ref={ref}
        >
            <Stack gap={3}>
                <RangeIndicator domain={domain} value={range} h={16} />
                <Group justify="space-between">
                    <Text size="xs" c="dimmed">
                        {formatTime(timestamp)}
                    </Text>
                    <Text size="xs" c="dimmed">
                        {index} / {total}
                    </Text>
                </Group>
            </Stack>
        </Timeline.Item>
    );
});
