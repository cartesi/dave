import { Group, Stack, Text, useMantineTheme } from "@mantine/core";
import { fromUnixTime } from "date-fns";
import { type FC } from "react";
import { TbClockExclamation } from "react-icons/tb";
import useRightColorShade from "../../../hooks/useRightColorShade";
import { ClaimText } from "../../tournament/ClaimText";
import type { Claim } from "../../types";
import { dateFormatter } from "./utils";

type TimeoutActionCardProps = {
    claim: Claim;
    timestamp: number;
};

export const TimeoutActionCard: FC<TimeoutActionCardProps> = ({
    claim,
    timestamp,
}) => {
    const theme = useMantineTheme();
    const warningColor = useRightColorShade("orange");
    const text = "timeout";

    return (
        <Stack>
            <Group justify="space-between">
                <ClaimText claim={claim} />
                <Text ff="monospace" fw="bold" tt="uppercase" c="dimmed">
                    {text}
                </Text>
            </Group>
            <Group justify="flex-end" gap="xs">
                <TbClockExclamation
                    size={theme.other.mdIconSize}
                    color={warningColor}
                />
                <Text c={warningColor} size="sm">
                    {dateFormatter.format(fromUnixTime(timestamp))}
                </Text>
            </Group>
        </Stack>
    );
};
