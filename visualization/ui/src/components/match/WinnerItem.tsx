import {
    Group,
    Paper,
    Stack,
    Text,
    Timeline,
    useMantineTheme,
} from "@mantine/core";
import humanizeDuration from "humanize-duration";
import { useMemo, type FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { ClaimText } from "../tournament/ClaimText";
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

    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];
    const dimmed = theme.colors.gray[5];

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
                <Paper
                    withBorder
                    p={16}
                    radius="lg"
                    bg={theme.colors.yellow[0]}
                >
                    <Stack>
                        <Group gap="xs">
                            <TbTrophyFilled size={24} color={gold} />
                            <ClaimText claim={winner} iconSize={24} />
                        </Group>
                        <Group gap="xs">
                            <TbTrophyFilled
                                size={24}
                                color={gold}
                                opacity={0}
                            />
                            <ClaimText
                                c="dimmed"
                                style={{ textDecoration: "line-through" }}
                                claim={loser}
                                iconSize={24}
                            />
                        </Group>
                    </Stack>
                </Paper>
                <Text size="xs" c="dimmed">
                    {formatTime(timestamp)}
                </Text>
            </Stack>
        </Timeline.Item>
    );
};
