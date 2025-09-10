import { Group, Stack, Text, Title } from "@mantine/core";
import { getUnixTime } from "date-fns";
import type { FC } from "react";
import { useParams } from "react-router";
import { keccak256, type Hex } from "viem";
import { useGetEpochTournament } from "../api/epoch.queries";
import { useGetMatch } from "../api/match.queries";
import {
    Hierarchy,
    type HierarchyConfig,
} from "../components/navigation/Hierarchy";
import { MatchBreadcrumbSegment } from "../components/navigation/MatchBreadcrumbSegment";
import { NotFound } from "../components/navigation/NotFound";
import { TournamentBreadcrumbSegment } from "../components/navigation/TournamentBreadcrumbSegment";
import type { Match } from "../components/types";
import { MatchPage } from "../pages/MatchPage";
import {
    routePathBuilder,
    type RoutePathParams,
} from "../routes/routePathBuilder";
import { ContainerSkeleton } from "./ContainerSkeleton";

const dummyMatch: Match = {
    actions: [],
    id: keccak256("0x1"),
    claim1: { hash: keccak256("0x2") },
    claim2: { hash: keccak256("0x3") },
    timestamp: 0,
};

export const MatchDetailContainer: FC = () => {
    const params = useParams<RoutePathParams>();
    const applicationId = params.appId ?? "";
    const parsedIndex = parseInt(params.epochIndex ?? "");
    const epochIndex = isNaN(parsedIndex) ? -1 : parsedIndex;
    const matchId = (params.matchId ?? "0x") as Hex;
    const nowUnixtime = getUnixTime(new Date());
    const appQuery = useGetEpochTournament({
        applicationId,
        epochIndex,
    });

    const matchQuery = useGetMatch({
        applicationId,
        epochIndex,
        matchId,
    });

    const isLoading = appQuery.isLoading || matchQuery.isLoading;
    const match = matchQuery.data?.match ?? null;
    const tournament = appQuery.data?.tournament ?? null;

    const hierarchyConfig: HierarchyConfig[] = [
        { title: "Home", href: "/" },
        { title: applicationId, href: routePathBuilder.appEpochs(params) },
        {
            title: `Epoch #${params.epochIndex}`,
            href: routePathBuilder.appEpochDetails(params),
        },
        {
            title: (
                <TournamentBreadcrumbSegment level="top" variant="default" />
            ),
            href: routePathBuilder.topTournament(params),
        },
        {
            title: (
                <MatchBreadcrumbSegment
                    match={match ?? dummyMatch}
                    variant="filled"
                />
            ),
            href: routePathBuilder.matchDetail(params),
        },
    ];

    return (
        <Stack pt="lg" gap="lg">
            <Hierarchy hierarchyConfig={hierarchyConfig} />

            {isLoading ? (
                <ContainerSkeleton />
            ) : tournament !== null && match !== null ? (
                <MatchPage
                    tournament={tournament}
                    match={match}
                    now={nowUnixtime}
                />
            ) : (
                <NotFound>
                    <Stack gap={2} align="center">
                        <Title c="dimmed" fw="bold" order={3}>
                            We're not able to find details about match{" "}
                            <Text c="orange" inherit component="span">
                                {params.matchId}
                            </Text>
                        </Title>

                        <Group gap={3}>
                            <Text c="dimmed">in application</Text>
                            <Text c="orange">{params.appId}</Text>
                            <Text c="dimmed">at epoch</Text>
                            <Text c="orange">{params.epochIndex}</Text>
                        </Group>
                    </Stack>
                </NotFound>
            )}
        </Stack>
    );
};
