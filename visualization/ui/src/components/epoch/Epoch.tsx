import {
    Badge,
    Card,
    Group,
    Stack,
    Text,
    type MantinePrimaryShade,
} from "@mantine/core";
import { useColorScheme, useMediaQuery } from "@mantine/hooks";
import type { FC } from "react";
import {
    TbClockCheck,
    TbClockExclamation,
    TbClockPlay,
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
        default:
            return "gray";
    }
};

type EpochIconProps = {
    status: EpochStatus;
    inDispute: boolean;
    colour: string;
};

const EpochIcon: FC<EpochIconProps> = ({ inDispute, status, colour }) => {
    if (inDispute === true)
        return (
            <TbClockExclamation size={theme.other.mdIconSize} color={colour} />
        );

    if (status === "CLOSED")
        return <TbClockCheck size={theme.other.mdIconSize} color={colour} />;

    if (status === "SEALED")
        return <TbClockShield size={theme.other.mdIconSize} color={colour} />;

    return <TbClockPlay size={theme.other.mdIconSize} color={colour} />;
};

const getCorrectShade = (scheme: "dark" | "light"): number => {
    const shade = theme.primaryShade as MantinePrimaryShade;
    return scheme === "dark" ? shade.dark : shade.light;
};

export const EpochCard: FC<Props> = ({ epoch }) => {
    const colorScheme = useColorScheme();
    const isMobile = useMediaQuery(`(max-width: ${theme.breakpoints.sm})`);
    const shadeIndex = getCorrectShade(colorScheme);
    const statusColour = getStatusColour(epoch.status);
    const disputeColour = theme.colors.orange[shadeIndex];
    const finalColour = epoch.inDispute
        ? disputeColour
        : theme.colors[statusColour][shadeIndex];

    return (
        <Card shadow="md" withBorder>
            <Stack gap="3">
                <Group justify="space-between" gap={isMobile ? "xs" : "xl"}>
                    <Group gap={isMobile ? "xs" : undefined}>
                        <EpochIcon
                            status={epoch.status}
                            inDispute={epoch.inDispute}
                            colour={finalColour}
                        />
                        <Text size="xl" c={finalColour}>
                            {epoch.index}
                        </Text>
                    </Group>
                    {epoch.inDispute && (
                        <Badge variant="outline" color={disputeColour}>
                            <Text
                                size={isMobile ? "xs" : "md"}
                                fw="bold"
                                tt="uppercase"
                                c={disputeColour}
                            >
                                in dispute
                            </Text>
                        </Badge>
                    )}
                    <Badge size="md" color={finalColour}>
                        {epoch.status}
                    </Badge>
                </Group>
            </Stack>
        </Card>
    );
};
