import { Badge, Card, Group, Text, useMantineTheme } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import type { FC } from "react";
import {
    TbClockCheck,
    TbClockExclamation,
    TbClockPlay,
    TbClockShield,
} from "react-icons/tb";
import type { Epoch } from "../types";

type Props = { epoch: Epoch };

const getIcon = (epoch: Epoch) => {
    if (epoch.inDispute) {
        return TbClockExclamation;
    }
    switch (epoch.status) {
        case "OPEN":
            return TbClockPlay;
        case "CLOSED":
            return TbClockShield;
        case "FINALIZED":
            return TbClockCheck;
    }
};

export const EpochCard: FC<Props> = ({ epoch }) => {
    const theme = useMantineTheme();
    const isMobile = useMediaQuery(`(max-width: ${theme.breakpoints.sm})`);
    const color = epoch.inDispute
        ? theme.colors.disputed
        : theme.colors[epoch.status.toLowerCase()];

    // choose icon based on status and dispute status
    const EpochIcon = getIcon(epoch);

    return (
        <Card shadow="md" withBorder>
            <Group justify="space-between" gap={isMobile ? "xs" : "xl"}>
                <Group gap="xs">
                    <EpochIcon size={theme.other.mdIconSize} color={color[5]} />
                    <Text size="xl" c={color[5]}>
                        # {epoch.index}
                    </Text>
                </Group>
                {epoch.inDispute && (
                    <Badge variant="outline" color={color[5]}>
                        disputed
                    </Badge>
                )}
                <Badge size="md" color={color[5]}>
                    {epoch.status}
                </Badge>
            </Group>
        </Card>
    );
};
