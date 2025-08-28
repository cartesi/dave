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
import { useEffect, useMemo, useRef, useState, type FC } from "react";
import { slice, zeroHash, type Hash } from "viem";
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
    bisections: (0 | 1)[];

    /**
     * First claim
     */
    claim1: Claim;

    /**
     * Second claim
     */
    claim2: Claim;
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const BisectionProgress: FC<BisectionProgressProps> = (props) => {
    const { claim1, claim2, range, bisections, max } = props;
    const [domain, setDomain] = useState<CycleRange>(range);

    const progress = (bisections.length / max) * 100;
    const [visibleProgress, setVisibleProgress] = useState(progress);

    // create ranges for each bisection
    const ranges = useMemo(
        () =>
            bisections.reduce(
                (r, bisection, i) => {
                    const l = r[i];
                    const [s, e] = l;
                    const mid = Math.floor((s + e) / 2);
                    r.push(bisection === 0 ? [s, mid] : [mid, e]);
                    return r;
                },
                [range],
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
    const [firstVisible, setFirstVisible] = useState(0);
    const [lastVisible, setLastVisible] = useState(0);

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
        if (firstVisible !== 0) {
            setDomain(ranges[firstVisible]);
        }
    }, [firstVisible]);

    // update progress bar based on last visible item
    useEffect(() => {
        if (lastVisible !== 0) {
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

    return (
        <Stack>
            <Group>
                <Avatar src={buildDataUrl(zeroHash)} size={24} opacity={0} />
                <Stack gap={3}>
                    <RangeIndicator
                        domain={range}
                        value={range}
                        withLabels
                        w={300}
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
            </Group>
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
                                    withLabels
                                    w={300}
                                    h={16}
                                />
                                <Text size="xs" c="dimmed">
                                    1 hour and 4 minutes ago
                                </Text>
                            </Stack>
                        </Timeline.Item>
                    ))}
                </Timeline>
            </ScrollArea>
        </Stack>
    );
};
