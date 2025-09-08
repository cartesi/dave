import { Badge, Card, Group, Stack, Text } from "@mantine/core";
import type { FC } from "react";
import { Link } from "react-router";
import { routePathBuilder } from "../../routes/routePathBuilder";
import type { Application, ApplicationState } from "../types";

type Props = { application: Application };

const getStateColour = (state: ApplicationState) => {
    switch (state) {
        case "ENABLED":
            return "green";
        case "DISABLED":
            return "red";
        case "INOPERABLE":
            return "gray";
        default:
            return "black";
    }
};

export const ApplicationCard: FC<Props> = ({ application }) => {
    const { address, consensusType, name, processedInputs, state } =
        application;
    const stateColour = getStateColour(state);
    const appId = application.name ?? application.address;
    const url = routePathBuilder.appEpochs({ appId });
    const inputsLabel =
        processedInputs === 0
            ? "no inputs"
            : processedInputs === 1
              ? `${processedInputs} input`
              : `${processedInputs} inputs`;

    return (
        <Card shadow="md" component={Link} to={url}>
            <Stack>
                <Stack gap="0">
                    <Group justify="space-between">
                        <Text size="xl">{name}</Text>
                    </Group>
                    <Text c="dimmed" size="xs">
                        {address}
                    </Text>
                </Stack>
                <Group justify="space-between">
                    <Badge variant="default">{inputsLabel}</Badge>
                    <Group gap="xs">
                        {state !== "ENABLED" && (
                            <Group gap="xs">
                                <Badge color={stateColour}>{state}</Badge>
                            </Group>
                        )}
                        <Badge>{consensusType}</Badge>
                    </Group>
                </Group>
            </Stack>
        </Card>
    );
};
