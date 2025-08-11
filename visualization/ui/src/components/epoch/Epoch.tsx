import { Badge, Card, Group, Indicator, Stack, Text } from "@mantine/core";
import type { FC } from "react";
import {
    TbClock,
    TbClockCheck,
    TbClockExclamation,
    TbClockShield,
} from "react-icons/tb";
import theme from "../../providers/theme";

type EpochStatus = "OPEN" | "SEALED" | "CLOSED";

export interface Epoch {
    index: number;
    status: EpochStatus;
    inDispute: boolean;
}

type Props = { epoch: Epoch };

const getStatusColour = (state: EpochStatus) => {
    switch (state) {
        case "OPEN":
            return "green";
        case "SEALED":
            return "cyan";
        case "CLOSED":
            return "teal";
        default:
            return "gray";
    }
};

type EpochIconProps = { status: EpochStatus; inDispute: boolean };

const EpochIcon: FC<EpochIconProps> = ({ inDispute, status }) => {
    if (inDispute === true)
        return <TbClockExclamation size={theme.other.mdIconSize} />;

    if (status === "CLOSED")
        return <TbClockCheck size={theme.other.mdIconSize} />;

    if (status === "SEALED")
        return <TbClockShield size={theme.other.mdIconSize} />;

    return <TbClock size={theme.other.mdIconSize} />;
};

export const EpochCard: FC<Props> = ({ epoch }) => {
    const statusColour = getStatusColour(epoch.status);
    const finalColour = epoch.inDispute ? "orange.9" : statusColour;

    return (
        <Indicator
            inline
            processing
            disabled={!epoch.inDispute}
            size="21"
            label="In Dispute"
            color={finalColour}
        >
            <Card shadow="md" withBorder>
                <Stack gap="0">
                    <Group justify="space-between" gap="xl">
                        <Group>
                            <EpochIcon
                                status={epoch.status}
                                inDispute={epoch.inDispute}
                            />
                            <Text size="xl">{epoch.index}</Text>
                        </Group>
                        <Badge size="md" color={statusColour}>
                            {epoch.status}
                        </Badge>
                    </Group>
                </Stack>
            </Card>
        </Indicator>
    );
};
