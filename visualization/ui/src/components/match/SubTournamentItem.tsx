import {
    Button,
    Group,
    Paper,
    Stack,
    useComputedColorScheme,
    useMantineTheme,
} from "@mantine/core";
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

    const theme = useMantineTheme();
    const scheme = useComputedColorScheme();
    const bg = scheme === "light" ? theme.colors.gray[0] : undefined;

    return (
        <ClaimTimelineItem claim={claim} now={now} timestamp={timestamp}>
            <Paper withBorder radius="lg" p={16} bg={bg}>
                <Group justify="space-between">
                    <Stack gap="xs">
                        <CycleRangeFormatted size="xs" range={range} />
                    </Stack>
                    <Button rightSection={<TbTrendingDown />}>{level}</Button>
                </Group>
            </Paper>
        </ClaimTimelineItem>
    );
};
