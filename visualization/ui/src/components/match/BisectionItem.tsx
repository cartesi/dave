import { Text, type TimelineItemProps } from "@mantine/core";
import { forwardRef, type FC } from "react";
import type { Claim, CycleRange } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";
import { RangeIndicator } from "./RangeIndicator";

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
    now: number;

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
    const { claim, domain, index, now, range, timestamp, total } = props;

    return (
        <ClaimTimelineItem
            claim={claim}
            now={now}
            ref={ref}
            rightSection={
                <Text size="xs" c="dimmed">
                    {index} / {total}
                </Text>
            }
            timestamp={timestamp}
        >
            <RangeIndicator
                domain={domain}
                value={range}
                h={16}
                color={props.color}
            />
        </ClaimTimelineItem>
    );
});
