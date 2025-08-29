import { Progress, Stack, Timeline, useMantineTheme } from "@mantine/core";
import { useEffect, useMemo, useState, type FC } from "react";
import { ScrollTimeline } from "../ScrollTimeline";
import type { Claim, CycleRange } from "../types";
import { BisectionItem } from "./BisectionItem";

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

export const BisectionProgress: FC<BisectionProgressProps> = (props) => {
    const { claim1, claim2, range, bisections, max } = props;

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
    const [firstVisible, setFirstVisible] = useState(-1);
    const [lastVisible, setLastVisible] = useState(-1);

    const updateVisibleIndices = (
        firstVisible: number,
        lastVisible: number,
    ) => {
        setFirstVisible(firstVisible);
        setLastVisible(lastVisible);
    };

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

    return (
        <Stack gap="lg">
            <Timeline bulletSize={24} lineWidth={2}>
                <Timeline.Item styles={{ itemBullet: { display: "none" } }}>
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
                </Timeline.Item>
            </Timeline>
            <ScrollTimeline
                bulletSize={24}
                lineWidth={2}
                h={300}
                onVisibleRangeChange={updateVisibleIndices}
            >
                {ranges.slice(1).map((r, i) => (
                    <BisectionItem
                        key={i}
                        claim={i % 2 === 0 ? claim1 : claim2}
                        color={theme.colors.gray[6]}
                        index={i + 1}
                        total={max}
                        domain={domain}
                        range={r}
                        timestamp={bisections[i].timestamp}
                    />
                ))}
            </ScrollTimeline>
        </Stack>
    );
};
