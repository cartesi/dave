import {
    Group,
    Stack,
    Text,
    Timeline,
    type TimelineItemProps,
} from "@mantine/core";
import humanizeDuration from "humanize-duration";
import { forwardRef } from "react";
import { HashAvatar } from "../HashAvatar";
import type { Claim } from "../types";

export interface ClaimTimelineItemProps extends TimelineItemProps {
    /**
     * The claim to display.
     */
    claim?: Claim;

    /**
     * The current timestamp.
     */
    now: number;

    /**
     * The component to show to the right of the timestamp.
     */
    rightSection?: React.ReactNode;

    /**
     * The timestamp to display.
     */
    timestamp?: number;
}

const formatTime = (now: number, timestamp: number) => {
    return `${humanizeDuration((now - timestamp) * 1000, { units: ["h", "m", "s"] })} ago`;
};

export const ClaimTimelineItem = forwardRef<
    HTMLDivElement,
    ClaimTimelineItemProps
>((props, ref) => {
    const { children, claim, now, rightSection, timestamp } = props;
    return (
        <Timeline.Item
            bullet={
                claim ? <HashAvatar hash={claim.hash} size={24} /> : undefined
            }
            ref={ref}
        >
            <Stack gap={3}>
                {(timestamp || rightSection) && (
                    <Group justify="space-between">
                        <Text size="xs" c="dimmed">
                            {timestamp ? formatTime(now, timestamp) : undefined}
                        </Text>
                        {rightSection}
                    </Group>
                )}
                {children}
            </Stack>
        </Timeline.Item>
    );
});
