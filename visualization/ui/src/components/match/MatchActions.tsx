import {
    Button,
    Group,
    Progress,
    Stack,
    Timeline,
    useMantineTheme,
} from "@mantine/core";
import {
    useElementSize,
    useInViewport,
    useMergedRef,
    useScrollIntoView,
} from "@mantine/hooks";
import { useEffect, useMemo, useState, type FC } from "react";
import { TbArrowUp } from "react-icons/tb";
import type { Claim, CycleRange, MatchAction } from "../types";
import { BisectionItem } from "./BisectionItem";
import { EliminationTimeoutItem } from "./EliminationTimeoutItem";
import { LoserItem } from "./LoserItem";
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
    const { actions, claim1, claim2, height, now } = props;

    // filter the bisection items
    const bisections = actions.filter((a) => a.type === "advance");

    // track the width of the timeline, so we can adjust the number of bars before size reset
    const { width: bisectionWidth, ref: bisectionWidthRef } = useElementSize();

    // calculate the number of bars until the size resets
    const [bars, setBars] = useState(bisections.length);
    useEffect(() => {
        const minWidth = 48;
        if (bisectionWidth === 0) {
            setBars(bisections.length);
        } else {
            setBars(Math.floor(Math.log2(bisectionWidth / minWidth)));
        }
    }, [bisectionWidth]);

    // dynamic domain, based on first visible item
    const maxRange: CycleRange = [0, 2 ** height];

    // progress bar, based on last visible item
    const progress = (bisections.length / height) * 100;

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

    // scroll hook points
    const { ref: topRefView, inViewport: topInViewport } = useInViewport();
    const { scrollIntoView: scrollToBottom, targetRef: bottomRef } =
        useScrollIntoView<HTMLDivElement>({
            offset: 60,
        });
    const { scrollIntoView: scrollToTop, targetRef: topRefScroll } =
        useScrollIntoView<HTMLDivElement>({
            offset: 60,
        });
    const ref = useMergedRef(bisectionWidthRef, topRefView, topRefScroll);

    // scroll to bottom on mount
    useEffect(() => {
        scrollToBottom();
    }, []);

    // colors for the progress bar
    const theme = useMantineTheme();
    const color = theme.primaryColor;

    return (
        <Stack>
            <Timeline ref={ref} bulletSize={24} lineWidth={2}>
                <Timeline.Item styles={{ itemBullet: { display: "none" } }}>
                    <Progress.Root>
                        <Progress.Section value={progress} color={color} />
                    </Progress.Root>
                </Timeline.Item>
            </Timeline>
            <Timeline bulletSize={24} lineWidth={2}>
                {actions.map((action, i) => {
                    const { timestamp } = action;
                    switch (action.type) {
                        case "advance":
                            return (
                                <BisectionItem
                                    key={i}
                                    claim={i % 2 === 0 ? claim1 : claim2}
                                    color={theme.colors.gray[6]}
                                    domain={ranges[Math.floor(i / bars) * bars]}
                                    expand={
                                        i % bars === bars - 1 &&
                                        i < bisections.length - 1
                                    }
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

                        case "leaf_match_sealed": {
                            const winner = (
                                <WinnerItem
                                    key={i}
                                    claim={
                                        action.winner === 1 ? claim1 : claim2
                                    }
                                    now={now}
                                    timestamp={timestamp}
                                    proof={action.proof}
                                />
                            );
                            const loser = (
                                <LoserItem
                                    claim={
                                        action.winner === 1 ? claim2 : claim1
                                    }
                                    now={now}
                                />
                            );
                            return i % 2 === 0 ? (
                                <>
                                    {winner}
                                    {loser}
                                </>
                            ) : (
                                <>
                                    {loser}
                                    {winner}
                                </>
                            );
                        }
                    }
                })}
            </Timeline>
            <Group justify="flex-end" ref={bottomRef}>
                {!topInViewport && (
                    <Button
                        variant="transparent"
                        leftSection={<TbArrowUp />}
                        onClick={() => scrollToTop()}
                    >
                        top
                    </Button>
                )}
            </Group>
        </Stack>
    );
};
