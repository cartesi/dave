import { Button, Group, Paper, Stack } from "@mantine/core";
import { type FC } from "react";
import { TbTrendingDown } from "react-icons/tb";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import type { Claim, CycleRange } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";

export interface SubTournamentItemProps {
    /**
     * Claim that took action.
     */
    claim: Claim;

    /**
     * Level of the sub tournament
     */
    level: "middle" | "bottom";

    /**
     * Current timestamp
     */
    now: number;

    /**
     * Cycle range
     */
    range: CycleRange;

    /**
     * Timestamp
     */
    timestamp: number;
}

export const SubTournamentItem: FC<SubTournamentItemProps> = (props) => {
    const { claim, level, now, range, timestamp } = props;

    return (
        <ClaimTimelineItem claim={claim} now={now} timestamp={timestamp}>
            <Paper withBorder radius="lg" p={16} bg="gray.0">
                <Group justify="space-between">
                    <Stack gap="xs">
                        <CycleRangeFormatted
                            size="xs"
                            c="dimmed"
                            range={range}
                        />
                    </Stack>
                    <Button rightSection={<TbTrendingDown />}>{level}</Button>
                </Group>
            </Paper>
        </ClaimTimelineItem>
    );
};
