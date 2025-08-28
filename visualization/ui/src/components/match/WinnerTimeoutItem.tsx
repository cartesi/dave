import {
    Avatar,
    Group,
    Paper,
    Stack,
    Text,
    Timeline,
    useMantineTheme,
} from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import humanizeDuration from "humanize-duration";
import { useMemo, type FC } from "react";
import { TbClockCancel, TbTrophyFilled } from "react-icons/tb";
import { slice, type Hash } from "viem";
import { ClaimText } from "../tournament/ClaimText";
import type { Claim } from "../types";

interface WinnerTimeoutItemProps {
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

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const WinnerTimeoutItem: FC<WinnerTimeoutItemProps> = (props) => {
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
        <>
            <Timeline.Item
                bullet={<Avatar src={buildDataUrl(loser.hash)} size={24} />}
            >
                <Group>
                    <TbClockCancel size={24} color={dimmed} />
                    <Text c="dimmed">no action taken</Text>
                </Group>
            </Timeline.Item>
            <Timeline.Item
                bullet={<Avatar src={buildDataUrl(winner.hash)} size={24} />}
            >
                <Stack gap={3}>
                    <Paper
                        withBorder
                        p={16}
                        radius="lg"
                        bg={theme.colors.yellow[0]}
                    >
                        <Group gap="xs">
                            <ClaimText claim={winner} withIcon={false} />
                            <TbTrophyFilled size={24} color={gold} />
                            <Text>by timeout</Text>
                        </Group>
                    </Paper>
                    <Text size="xs" c="dimmed">
                        {formatTime(timestamp)}
                    </Text>
                </Stack>
            </Timeline.Item>
        </>
    );
};
