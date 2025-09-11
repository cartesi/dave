import { Group, Stack, Text, Title } from "@mantine/core";
import type { FC } from "react";
import { useParams } from "react-router";
import type { Hex } from "viem";
import {
    useFindMatch,
    useGetMatch,
    useGetMatchTournament,
} from "../api/match.queries";
import {
    Hierarchy,
    type HierarchyConfig,
} from "../components/navigation/Hierarchy";
import { MatchBreadcrumbSegment } from "../components/navigation/MatchBreadcrumbSegment";
import { NotFound } from "../components/navigation/NotFound";
import { TournamentBreadcrumbSegment } from "../components/navigation/TournamentBreadcrumbSegment";
import type { Match } from "../components/types";
import { TournamentPage } from "../pages/TournamentPage";
import {
    routePathBuilder,
    type RoutePathParams,
} from "../routes/routePathBuilder";
import { dummyMatch } from "../stories/data";
import { ContainerSkeleton } from "./ContainerSkeleton";

interface Props {
    level?: "middle" | "bottom";
}

interface BuildHierarchyProps {
    params: RoutePathParams;
    level: "middle" | "bottom";
    match: Match | null;
    midMatch: Match | null;
}

const buildHierarchy = ({
    level,
    params,
    match,
    midMatch,
}: BuildHierarchyProps): HierarchyConfig[] => {
    const base = [
        { title: "Home", href: "/" },
        { title: params.appId, href: routePathBuilder.appEpochs(params) },
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
                    variant="default"
                />
            ),
            href: routePathBuilder.matchDetail(params),
        },
        {
            title: (
                <TournamentBreadcrumbSegment
                    level="middle"
                    variant={level === "middle" ? "filled" : "default"}
                />
            ),
            href: routePathBuilder.middleTournament(params),
        },
    ];

    if (level === "bottom") {
        return [
            ...base,
            {
                title: (
                    <MatchBreadcrumbSegment
                        match={midMatch ?? dummyMatch}
                        variant="default"
                    />
                ),
                href: routePathBuilder.matchDetail(params),
            },
            {
                title: (
                    <TournamentBreadcrumbSegment
                        level="bottom"
                        variant="filled"
                    />
                ),
                href: routePathBuilder.bottomTournament(params),
            },
        ];
    }

    return base;
};

export const SubTournamentContainer: FC<Props> = ({ level = "middle" }) => {
    const params = useParams<RoutePathParams>();
    const applicationId = params.appId ?? "";
    const parsedIndex = parseInt(params.epochIndex ?? "");
    const epochIndex = isNaN(parsedIndex) ? -1 : parsedIndex;
    const matchId = (params.matchId ?? "0x") as Hex;
    const midMatchId = (params.midMatchId ?? "0x") as Hex;

    const midTournamentQuery = useGetMatchTournament({
        applicationId,
        epochIndex,
        matchId,
    });

    const bottomTournamentQuery = useGetMatchTournament({
        applicationId,
        epochIndex,
        matchId: midMatchId,
    });

    const matchQuery = useGetMatch({
        applicationId,
        epochIndex,
        matchId,
    });

    const midTournament = midTournamentQuery.data?.tournament ?? null;
    const bottomTournament = bottomTournamentQuery.data?.tournament ?? null;

    const tournament = level === "middle" ? midTournament : bottomTournament;

    const midMatchQuery = useFindMatch({
        applicationId,
        epochIndex,
        matchId: midMatchId,
        tournamentId: midTournament?.id ?? "0x",
        enabled: midTournament !== null,
    });

    const isLoading =
        bottomTournamentQuery.isLoading ||
        midTournamentQuery.isLoading ||
        matchQuery.isLoading ||
        midMatchQuery.isLoading;
    const match = matchQuery.data?.match ?? null;
    const midMatch = midMatchQuery.data?.match ?? null;

    const hierarchyConfig: HierarchyConfig[] = buildHierarchy({
        level,
        match,
        midMatch,
        params,
    });

    return (
        <Stack pt="lg" gap="lg">
            <Hierarchy hierarchyConfig={hierarchyConfig} />

            {isLoading ? (
                <ContainerSkeleton />
            ) : tournament !== null ? (
                <TournamentPage tournament={tournament} />
            ) : (
                <NotFound>
                    <Stack gap={2} align="center">
                        <Title c="dimmed" fw="bold" order={3} ta="center">
                            We're not able to find the sub tournament from match{" "}
                            <Text c="orange" inherit component="span">
                                {params.matchId}
                            </Text>
                        </Title>
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
