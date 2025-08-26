import {
    Badge,
    Group,
    Stack,
    Text,
    useMantineTheme,
    type MantineColor,
} from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import { fromUnixTime } from "date-fns";
import { type FC } from "react";
import { TbClockExclamation } from "react-icons/tb";
import useRightColorShade from "../../../hooks/useRightColorShade";
import { ClaimText } from "../../tournament/ClaimText";
import type { Claim } from "../../types";
import { dateFormatter } from "./utils";

type TimeoutActionCardProps = {
    claimOne: Claim;
    claimTwo: Claim;
    timestamp: number;
};

type Props = {
    color: MantineColor;
    iconSize: number;
    isSmallDevice: boolean;
    timestamp: number;
};

const Timeout: FC<Props> = ({ color, iconSize, isSmallDevice, timestamp }) => {
    return (
        <Group gap="xs">
            <TbClockExclamation size={iconSize} color={color} />
            <Text c={color} size={isSmallDevice ? "sm" : ""}>
                {dateFormatter.format(fromUnixTime(timestamp))}
            </Text>
        </Group>
    );
};

export const EliminatedByTimeoutActionCard: FC<TimeoutActionCardProps> = ({
    claimOne,
    claimTwo,
    timestamp,
}) => {
    const theme = useMantineTheme();
    const warningColor = useRightColorShade("orange");
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const text = "Match Eliminated";
    const reason = "Timeout";

    return (
        <Stack gap="xs">
            <Group justify="space-between">
                {!isSmallDevice && (
                    <Timeout
                        color={warningColor}
                        iconSize={theme.other.mdIconSize}
                        isSmallDevice={isSmallDevice}
                        timestamp={timestamp}
                    />
                )}
                <Badge variant="outline" color={warningColor}>
                    {reason}
                </Badge>

                <Text ff="monospace" fw="bold" tt="uppercase" c="dimmed">
                    {text}
                </Text>
            </Group>
            {isSmallDevice && (
                <Timeout
                    color={warningColor}
                    iconSize={theme.other.mdIconSize}
                    isSmallDevice={isSmallDevice}
                    timestamp={timestamp}
                />
            )}
            <Stack>
                <ClaimText
                    claim={claimOne}
                    td="line-through"
                    c={"dimmed"}
                    shorten={isSmallDevice ? 13 : false}
                />
                <ClaimText
                    claim={claimTwo}
                    td="line-through"
                    c={"dimmed"}
                    shorten={isSmallDevice ? 13 : false}
                />
            </Stack>
        </Stack>
    );
};
