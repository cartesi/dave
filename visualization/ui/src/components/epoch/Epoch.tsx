import { Badge, Card, Group, Text, useMantineTheme } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import type { FC } from "react";
import type { Epoch } from "../types";

type Props = { epoch: Epoch };

export const EpochCard: FC<Props> = ({ epoch }) => {
    const theme = useMantineTheme();
    const isMobile = useMediaQuery(`(max-width: ${theme.breakpoints.sm})`);
    const color = epoch.inDispute
        ? theme.colors.disputed
        : theme.colors[epoch.status.toLowerCase()];

    return (
        <Card shadow="md" withBorder>
            <Group justify="space-between" gap={isMobile ? "xs" : "xl"}>
                <Text size="xl"># {epoch.index}</Text>
                {epoch.inDispute && (
                    <Badge variant="outline" color={color[7]}>
                        disputed
                    </Badge>
                )}
                <Badge size="md" color={color[7]}>
                    {epoch.status}
                </Badge>
            </Group>
        </Card>
    );
};
