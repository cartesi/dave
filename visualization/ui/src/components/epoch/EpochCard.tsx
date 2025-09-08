import { Badge, Card, Group, Text, useMantineTheme } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import type { FC } from "react";
import { Link, useParams } from "react-router";
import { routePathBuilder } from "../../routes/routePathBuilder";
import type { Epoch } from "../types";
import { useEpochStatusColor } from "./useEpochStatusColor";

type Props = { epoch: Epoch };

export const EpochCard: FC<Props> = ({ epoch }) => {
    const theme = useMantineTheme();
    const params = useParams();
    const epochIndex = epoch.index?.toString() ?? "0";
    const url = routePathBuilder.appEpochDetails({ ...params, epochIndex });
    const isMobile = useMediaQuery(`(max-width: ${theme.breakpoints.sm})`);
    const color = useEpochStatusColor(epoch);

    return (
        <Card shadow="md" withBorder component={Link} to={url}>
            <Group justify="space-between" gap={isMobile ? "xs" : "xl"}>
                <Text size="xl"># {epoch.index}</Text>
                {epoch.inDispute && (
                    <Badge variant="outline" color={color}>
                        disputed
                    </Badge>
                )}
                <Badge size="md" color={color}>
                    {epoch.status}
                </Badge>
            </Group>
        </Card>
    );
};
