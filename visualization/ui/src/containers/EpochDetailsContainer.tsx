import { Group, Stack, Text } from "@mantine/core";
import type { FC } from "react";
import { useParams } from "react-router";
import { useGetEpoch, useGetEpochTournament } from "../api/epoch.queries";
import { useListInputs } from "../api/inputs.queries";
import {
    Hierarchy,
    type HierarchyConfig,
} from "../components/navigation/Hierarchy";
import { NotFound } from "../components/navigation/NotFound";
import { EpochDetailsPage } from "../pages/EpochDetailsPage";
import { routePathBuilder } from "../routes/routePathBuilder";
import { ContainerSkeleton } from "./ContainerSkeleton";

export const EpochDetailsContainer: FC = () => {
    const params = useParams();
    const applicationId = params.appId ?? "";
    const parsedIndex = parseInt(params.epochIndex ?? "");
    const epochIndex = isNaN(parsedIndex) ? -1 : parsedIndex;
    const epochQuery = useGetEpoch({ applicationId, epochIndex });
    const tournamentQuery = useGetEpochTournament({
        applicationId,
        epochIndex,
    });
    const inputsQuery = useListInputs({ applicationId, epochIndex });

    const epoch = epochQuery.data?.epoch ?? null;
    const tournament = tournamentQuery.data?.tournament ?? null;
    const inputs = inputsQuery.data?.inputs ?? [];
    const isLoading =
        epochQuery.isLoading ||
        tournamentQuery.isLoading ||
        inputsQuery.isLoading;

    const hierarchyConfig: HierarchyConfig[] = [
        { title: "Home", href: "/" },
        { title: applicationId, href: routePathBuilder.appEpochs(params) },
        {
            title: `Epoch #${params.epochIndex}`,
            href: routePathBuilder.appEpochDetails(params),
        },
    ];

    return (
        <Stack pt="lg" gap="lg">
            <Hierarchy hierarchyConfig={hierarchyConfig} />

            {isLoading ? (
                <ContainerSkeleton />
            ) : epoch !== null ? (
                <EpochDetailsPage
                    tournament={tournament}
                    epoch={epoch}
                    inputs={inputs}
                />
            ) : (
                <NotFound>
                    <Group gap={3}>
                        <Text c="dimmed">We're not able to find the epoch</Text>
                        <Text c="orange">{params.epochIndex}</Text>
                        <Text c="dimmed">for application</Text>
                        <Text c="orange">{applicationId}</Text>
                    </Group>
                </NotFound>
            )}
        </Stack>
    );
};
