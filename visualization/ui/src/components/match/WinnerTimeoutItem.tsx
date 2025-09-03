import {
    Group,
    Paper,
    Text,
    useComputedColorScheme,
    useMantineTheme,
} from "@mantine/core";
import { type FC } from "react";
import { TbClockCancel, TbTrophyFilled } from "react-icons/tb";
import { ClaimText } from "../tournament/ClaimText";
import type { Claim } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";

interface WinnerTimeoutItemProps {
    /**
     * Loser claim
     */
    loser: Claim;

    /**
     * Current timestamp
     */
    now: number;

    /**
     * Item timestamp
     */
    timestamp: number;

    /**
     * Winner claim
     */
    winner: Claim;
}

export const WinnerTimeoutItem: FC<WinnerTimeoutItemProps> = (props) => {
    const { loser, now, timestamp, winner } = props;

    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    const scheme = useComputedColorScheme();
    const bg = scheme === "light" ? theme.colors.yellow[0] : undefined;

    return (
        <>
            <ClaimTimelineItem claim={loser} now={now}>
                <Group c="dimmed">
                    <TbClockCancel size={24} />
                    <Text>no action taken</Text>
                </Group>
            </ClaimTimelineItem>
            <ClaimTimelineItem claim={winner} now={now} timestamp={timestamp}>
                <Paper withBorder p={16} radius="lg" bg={bg}>
                    <Group gap="xs">
                        <TbTrophyFilled size={24} color={gold} />
                        <ClaimText claim={winner} withIcon={false} />
                        <Text>(by timeout)</Text>
                    </Group>
                </Paper>
            </ClaimTimelineItem>
        </>
    );
};
