import { Group, Stack, Text } from "@mantine/core";
import type { FC } from "react";
import { useParams } from "react-router";
import { useGetEpochTournament } from "../api/epoch.queries";
import {
    Hierarchy,
    type HierarchyConfig,
} from "../components/navigation/Hierarchy";
import { NotFound } from "../components/navigation/NotFound";
import { TournamentBreadcrumbSegment } from "../components/navigation/TournamentBreadcrumbSegment";
import { TournamentPage } from "../pages/TournamentPage";
import { routePathBuilder } from "../routes/routePathBuilder";
import { ContainerSkeleton } from "./ContainerSkeleton";

export const TournamentContainer: FC = () => {
    const params = useParams();
    const applicationId = params.appId ?? "";
    const parsedIndex = parseInt(params.epochIndex ?? "");
    const epochIndex = isNaN(parsedIndex) ? -1 : parsedIndex;
    const { isLoading, data } = useGetEpochTournament({
        applicationId,
        epochIndex,
    });

    const hierarchyConfig: HierarchyConfig[] = [
        { title: "Home", href: "/" },
        { title: applicationId, href: routePathBuilder.appEpochs(params) },
        {
            title: `Epoch #${params.epochIndex}`,
            href: routePathBuilder.appEpochDetails(params),
        },
        {
            title: <TournamentBreadcrumbSegment level="top" variant="filled" />,
            href: routePathBuilder.topTournament(params),
        },
    ];

    const tournament = data?.tournament ?? null;

    return (
        <Stack pt="lg" gap="lg">
            <Hierarchy hierarchyConfig={hierarchyConfig} />

            {isLoading ? (
                <ContainerSkeleton />
            ) : tournament !== null ? (
                <TournamentPage tournament={tournament} />
            ) : (
                <NotFound>
                    <Stack gap={2}>
                        <Text c="dimmed" fw="bold">
                            We're not able to find the tournament
                        </Text>
                        <Group gap={3}>
                            <Text c="dimmed">for application</Text>
                            <Text c="orange">{applicationId}</Text>
                            <Text c="dimmed">at epoch</Text>
                            <Text c="orange">{params.epochIndex}</Text>
                        </Group>
                    </Stack>
                </NotFound>
            )}
        </Stack>
    );
};
