import { Stack, Text, type TimelineItemProps } from "@mantine/core";
import { forwardRef, useMemo, type FC } from "react";
import type { Claim, CycleRange } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";
import { CurlyBracket } from "./CurlyBracket";
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
     * Whether to expand the bisection to a full range
     */
    expand?: boolean;

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
    const { claim, domain, expand, index, now, range, timestamp, total } =
        props;

    // percentage of the middle of the range relative to the bar
    const p = useMemo(() => {
        const [start, end] = range;
        const [domainStart, domainEnd] = domain;
        return (
            (start + end - 2 * domainStart) / (2 * (domainEnd - domainStart))
        );
    }, [domain, range]);

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
            <Stack gap="xs">
                <RangeIndicator
                    domain={domain}
                    value={range}
                    h={16}
                    color={props.color}
                />
                {expand && (
                    <>
                        <CurlyBracket
                            color={props.color}
                            h={14}
                            strokeWidth={2}
                            tip={p}
                        />
                        <RangeIndicator
                            domain={[0, 1]}
                            value={[0, 1]}
                            h={16}
                            color={props.color}
                        />
                    </>
                )}
            </Stack>
        </ClaimTimelineItem>
    );
});
