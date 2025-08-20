import { Badge, Card, Group, Stack, Text } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import type { FC } from "react";
import {
    TbClockCheck,
    TbClockExclamation,
    TbClockPlay,
    TbClockShield,
} from "react-icons/tb";
import theme from "../../providers/theme";
import type { Epoch, EpochStatus } from "../types";
import { useEpochStatusColor } from "./useEpochStatusColor";

type Props = { epoch: Epoch };

type EpochIconProps = {
    status: EpochStatus;
    inDispute: boolean;
    color: string;
};

const EpochIcon: FC<EpochIconProps> = ({ inDispute, status, color }) => {
    if (inDispute === true)
        return (
            <TbClockExclamation size={theme.other.mdIconSize} color={color} />
        );

    if (status === "FINALIZED")
        return <TbClockCheck size={theme.other.mdIconSize} color={color} />;

    if (status === "SEALED")
        return <TbClockShield size={theme.other.mdIconSize} color={color} />;

    return <TbClockPlay size={theme.other.mdIconSize} color={color} />;
};

export const EpochCard: FC<Props> = ({ epoch }) => {
    const isMobile = useMediaQuery(`(max-width: ${theme.breakpoints.sm})`);
    const statusColor = useEpochStatusColor(epoch);

    return (
        <Card shadow="md" withBorder>
            <Stack gap="3">
                <Group justify="space-between" gap={isMobile ? "xs" : "xl"}>
                    <Group gap={isMobile ? "xs" : undefined}>
                        <EpochIcon
                            status={epoch.status}
                            inDispute={epoch.inDispute}
                            color={statusColor}
                        />
                        <Text size="xl" c={statusColor}>
                            {epoch.index}
                        </Text>
                    </Group>
                    {epoch.inDispute && (
                        <Badge variant="outline" color={statusColor}>
                            disputed
                        </Badge>
                    )}
                    <Badge size="md" color={statusColor}>
                        {epoch.status}
                    </Badge>
                </Group>
            </Stack>
        </Card>
    );
};
