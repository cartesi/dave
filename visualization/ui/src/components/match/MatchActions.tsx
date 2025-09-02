import { Progress, Stack, Timeline, useMantineTheme } from "@mantine/core";
import { useEffect, useMemo, useState, type FC } from "react";
import { ScrollTimeline } from "../ScrollTimeline";
import type { Claim, CycleRange, MatchAction } from "../types";
import { BisectionItem } from "./BisectionItem";
import { EliminationTimeoutItem } from "./EliminationTimeoutItem";
import { SubTournamentItem } from "./SubTournamentItem";
import { WinnerItem } from "./WinnerItem";
import { WinnerTimeoutItem } from "./WinnerTimeoutItem";

interface MatchActionsProps {
    /**
     * List of actions to display
     */
    actions: MatchAction[];

    /**
     * Whether to auto-adjust the ranges of the bisection items as user scrolls
     */
    autoAdjustRanges?: boolean;

    /**
     * First claim
     */
    claim1: Claim;

    /**
     * Second claim
     */
    claim2: Claim;

    /**
     * Maximum number of bisections to reach the target subdivision
     */
    height: number;

    /**
     * Current timestamp
     */
    now: number;
}

export const MatchActions: FC<MatchActionsProps> = (props) => {
    const {
        actions,
        autoAdjustRanges = true,
        claim1,
        claim2,
        height,
        now,
    } = props;

    // filter the bisection items
    const bisections = actions.filter((a) => a.type === "advance");

    // dynamic domain, based on first visible item
    const maxRange: CycleRange = [0, 2 ** height];
    const [domain, setDomain] = useState<CycleRange>(maxRange);

    // progress bar, based on last visible item
    const progress = (bisections.length / height) * 100;
    const [visibleProgress, setVisibleProgress] = useState(progress);

    const [firstVisible, setFirstVisible] = useState(-1);

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

    const onVisibleRangeChange = (
        firstVisible: number,
        lastVisible: number,
    ) => {
        setFirstVisible(firstVisible);

        // adjust secondary progress color according to the last visible item in the scroll area
        if (lastVisible >= 0) {
            setVisibleProgress(((lastVisible + 1) / height) * 100);
        }
    };

    useEffect(() => {
        if (!autoAdjustRanges) {
            setDomain(maxRange);
        } else if (firstVisible >= 0) {
            // adjust domain based on the first visible item in the scroll area
            setDomain(ranges[firstVisible]);
        }
    }, [autoAdjustRanges, firstVisible]);

    return (
        <Stack>
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
                h={400}
                onVisibleRangeChange={onVisibleRangeChange}
            >
                {actions.map((action, i) => {
                    const { timestamp } = action;
                    switch (action.type) {
                        case "advance":
                            return (
                                <BisectionItem
                                    key={i}
                                    claim={i % 2 === 0 ? claim1 : claim2}
                                    color={theme.colors.gray[6]}
                                    domain={domain}
                                    index={i + 1}
                                    now={now}
                                    range={ranges[i + 1]}
                                    timestamp={timestamp}
                                    total={height}
                                />
                            );

                        case "timeout":
                            return (
                                <WinnerTimeoutItem
                                    key={i}
                                    loser={i % 2 === 0 ? claim1 : claim2}
                                    now={now}
                                    timestamp={timestamp}
                                    winner={i % 2 === 0 ? claim2 : claim1}
                                />
                            );

                        case "match_eliminated_by_timeout":
                            return (
                                <EliminationTimeoutItem
                                    key={i}
                                    claim1={i % 2 === 0 ? claim1 : claim2}
                                    claim2={i % 2 === 0 ? claim2 : claim1}
                                    now={now}
                                    timestamp={timestamp}
                                />
                            );

                        case "match_sealed_inner_tournament_created":
                            return (
                                <SubTournamentItem
                                    claim={i % 2 === 0 ? claim1 : claim2}
                                    key={i}
                                    level="middle"
                                    now={now}
                                    range={action.range}
                                    timestamp={timestamp}
                                />
                            );

                        case "leaf_match_sealed":
                            return (
                                <WinnerItem
                                    key={i}
                                    now={now}
                                    timestamp={timestamp}
                                    loser={
                                        action.winner === 1 ? claim2 : claim1
                                    }
                                    winner={
                                        action.winner === 1 ? claim1 : claim2
                                    }
                                />
                            );
                    }
                })}
            </ScrollTimeline>
        </Stack>
    );
};
