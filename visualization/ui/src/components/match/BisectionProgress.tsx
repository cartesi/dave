import {
    Avatar,
    Group,
    Progress,
    ScrollArea,
    Stack,
    Text,
    Timeline,
    useMantineTheme,
} from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import humanizeDuration from "humanize-duration";
import { useEffect, useMemo, useRef, useState, type FC } from "react";
import { slice, type Hash } from "viem";
import type { Claim, CycleRange } from "../types";
import { RangeIndicator } from "./RangeIndicator";

interface BisectionProgressProps {
    /**
     * The range being bisected
     */
    range: CycleRange;

    /**
     * Maximum number of bisections to reach the target subdivision
     */
    max: number;

    /**
     * List of bisections. 0 is left, 1 is right
     */
    bisections: { direction: 0 | 1; timestamp: number }[];

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
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const BisectionProgress: FC<BisectionProgressProps> = (props) => {
    const { claim1, claim2, range, bisections, max } = props;

    // allow now to be defined outside, default to Date.now
    const now = useMemo(
        () => props.now ?? Math.floor(Date.now() / 1000),
        [props.now],
    );

    // dynamic domain, based on first visible item
    const maxRange: CycleRange = [0, 2 ** max - 1];
    const [domain, setDomain] = useState<CycleRange>(maxRange);

    // progress bar, based on last visible item
    const progress = (bisections.length / max) * 100;
    const [visibleProgress, setVisibleProgress] = useState(progress);

    // create ranges for each bisection
    const ranges = useMemo(
        () =>
            bisections.reduce(
                (r, bisection, i) => {
                    const { direction } = bisection;
                    const l = r[i];
                    const [s, e] = l;
                    const mid = Math.floor((s + e) / 2);
                    r.push(direction === 0 ? [s, mid] : [mid, e]);
                    return r;
                },
                [maxRange],
            ),
        [bisections],
    );

    // colors for the progress bar
    const theme = useMantineTheme();
    const color = theme.primaryColor;
    const colorLight = theme.colors[theme.primaryColor][4];

    // refs for the scroll area and timeline items visibility
    const viewportRef = useRef<HTMLDivElement>(null);
    const itemRefs = useRef<(HTMLDivElement | null)[]>([]);
    const [firstVisible, setFirstVisible] = useState(-1);
    const [lastVisible, setLastVisible] = useState(-1);

    const updateVisibleIndices = () => {
        if (!viewportRef.current) return;
        const scrollTop = viewportRef.current.scrollTop;
        const viewportHeight = viewportRef.current.clientHeight;

        const visibleIndices = itemRefs.current
            .map((el, idx) => {
                if (!el) return null;
                const itemTop = el.offsetTop;
                const itemBottom = el.offsetTop + el.offsetHeight;

                // partially visible counts
                if (
                    itemBottom > scrollTop &&
                    itemTop < scrollTop + viewportHeight
                ) {
                    return idx;
                }
                return null;
            })
            .filter((idx): idx is number => idx !== null);

        if (visibleIndices.length > 0) {
            setFirstVisible(visibleIndices[0]);
            setLastVisible(visibleIndices[visibleIndices.length - 1]);
        }
    };

    // update visible indices on mount
    useEffect(() => {
        updateVisibleIndices();
    }, []);

    // update range based on first visible item
    useEffect(() => {
        if (firstVisible >= 0) {
            setDomain(ranges[firstVisible]);
        }
    }, [firstVisible]);

    // update progress bar based on last visible item
    useEffect(() => {
        if (lastVisible >= 0) {
            setVisibleProgress(((lastVisible + 1) / max) * 100);
        }
    }, [lastVisible]);

    // scroll to bottom on mount
    useEffect(() => {
        if (viewportRef.current) {
            viewportRef.current.scrollTo({
                top: viewportRef.current.scrollHeight,
            });
        }
    }, []);

    const formatTime = (timestamp: number) => {
        return `${humanizeDuration((now - timestamp) * 1000, { units: ["h", "m", "s"] })} ago`;
    };

    return (
        <Stack gap="lg">
            <Timeline bulletSize={24} lineWidth={2}>
                <Timeline.Item styles={{ itemBullet: { display: "none" } }}>
                    <Stack gap={3}>
                        <RangeIndicator
                            domain={range}
                            value={range}
                            withLabels
                            h={16}
                        />
                        <Progress.Root>
                            <Progress.Section
                                value={visibleProgress}
                                color={color}
                            />
                            <Progress.Section
                                value={progress - visibleProgress}
                                color={colorLight}
                            />
                        </Progress.Root>
                    </Stack>
                </Timeline.Item>
            </Timeline>
            <ScrollArea
                h={300}
                viewportRef={viewportRef}
                type="auto"
                scrollbars="y"
                onScrollPositionChange={updateVisibleIndices}
            >
                <Timeline bulletSize={24} lineWidth={2}>
                    {ranges.slice(1).map((r, i) => (
                        <Timeline.Item
                            key={i}
                            ref={(el) => {
                                itemRefs.current[i] = el;
                            }}
                            bullet={
                                <Avatar
                                    src={buildDataUrl(
                                        i % 2 === 0 ? claim1.hash : claim2.hash,
                                    )}
                                    size={24}
                                />
                            }
                        >
                            <Stack gap={3}>
                                <RangeIndicator
                                    domain={domain}
                                    value={r}
                                    h={16}
                                />
                                <Group justify="space-between">
                                    <Text size="xs" c="dimmed">
                                        {formatTime(bisections[i].timestamp)}
                                    </Text>
                                    <Text size="xs" c="dimmed">
                                        {i + 1} / {max}
                                    </Text>
                                </Group>
                            </Stack>
                        </Timeline.Item>
                    ))}
                </Timeline>
            </ScrollArea>
        </Stack>
    );
};
