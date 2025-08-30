import { Stack, Text, Timeline } from "@mantine/core";
import humanizeDuration from "humanize-duration";
import { useMemo, type FC } from "react";
import { MatchCard } from "../tournament/MatchCard";
import type { Claim } from "../types";

export interface WinnerItemProps {
    /**
     * Loser claim
     */
    loser: Claim;

    /**
     * Current timestamp
     */
    now?: number;

    /**
     * Timestamp
     */
    timestamp: number;

    /**
     * Winner claim
     */
    winner: Claim;
}

export const WinnerItem: FC<WinnerItemProps> = (props) => {
    const { loser, timestamp, winner } = props;

    // allow now to be defined outside, default to Date.now
    const now = useMemo(
        () => props.now ?? Math.floor(Date.now() / 1000),
        [props.now],
    );

    const formatTime = (timestamp: number) => {
        return `${humanizeDuration((now - timestamp) * 1000, { units: ["h", "m", "s"] })} ago`;
    };

    return (
        <Timeline.Item>
            <Stack gap={3}>
                <MatchCard
                    match={{
                        actions: [],
                        claim1: winner,
                        claim2: loser,
                        timestamp,
                        winner: 1,
                    }}
                />
                <Text size="xs" c="dimmed">
                    {formatTime(timestamp)}
                </Text>
            </Stack>
        </Timeline.Item>
    );
};
