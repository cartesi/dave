import { Group, Stack, Text, Title } from "@mantine/core";
import { getUnixTime } from "date-fns";
import type { FC } from "react";
import { useParams } from "react-router";
import { type Hex } from "viem";
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
import { MatchPage } from "../pages/MatchPage";
import {
    routePathBuilder,
    type RoutePathParams,
} from "../routes/routePathBuilder";
import { dummyMatch } from "../stories/data";
import { ContainerSkeleton } from "./ContainerSkeleton";

interface BuildHierarchyProps {
    params: RoutePathParams;
    level: "middle" | "bottom";
    match: Match | null;
    midMatch: Match | null;
    btMatch: Match | null;
}

const buildHierarchy = ({
    level,
    params,
    match,
    midMatch,
    btMatch,
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
                <TournamentBreadcrumbSegment level="middle" variant="default" />
            ),
            href: routePathBuilder.middleTournament(params),
        },
        {
            title: (
                <MatchBreadcrumbSegment
                    match={midMatch ?? dummyMatch}
                    variant={level === "middle" ? "filled" : "default"}
                />
            ),
            href: routePathBuilder.midMatchDetail(params),
        },
    ];

    if (level === "bottom") {
        return [
            ...base,
            {
                title: (
                    <TournamentBreadcrumbSegment
                        level="bottom"
                        variant="default"
                    />
                ),
                href: routePathBuilder.bottomTournament(params),
            },
            {
                title: (
                    <MatchBreadcrumbSegment
                        match={btMatch ?? dummyMatch}
                        variant="filled"
                    />
                ),
                href: routePathBuilder.btMatchDetail(params),
            },
        ];
    }

    return base;
};

interface Props {
    level?: "middle" | "bottom";
}

export const SubMatchDetailContainer: FC<Props> = ({ level = "middle" }) => {
    const params = useParams<RoutePathParams>();
    const applicationId = params.appId ?? "";
    const parsedIndex = parseInt(params.epochIndex ?? "");
    const epochIndex = isNaN(parsedIndex) ? -1 : parsedIndex;
    const matchId = (params.matchId ?? "0x") as Hex;
    const midMatchId = (params.midMatchId ?? "0x") as Hex;
    const btMatchId = (params.btMatchId ?? "0x") as Hex;

    const nowUnixtime = getUnixTime(new Date());

    const midTournamentQuery = useGetMatchTournament({
        applicationId,
        epochIndex,
        matchId: matchId,
    });

    const btTournamentQuery = useGetMatchTournament({
        applicationId,
        epochIndex,
        matchId: midMatchId,
    });

    const midTournament = midTournamentQuery.data?.tournament ?? null;
    const btTournament = btTournamentQuery.data?.tournament ?? null;

    const matchQuery = useGetMatch({
        applicationId,
        epochIndex,
        matchId,
    });

    const midMatchQuery = useFindMatch({
        applicationId,
        epochIndex,
        matchId: midMatchId,
        tournamentId: midTournament?.id ?? "0x",
        enabled: midTournament !== null,
    });

    const btMatchQuery = useFindMatch({
        applicationId,
        epochIndex,
        matchId: btMatchId,
        tournamentId: btTournament?.id ?? "0x",
        enabled: btTournament !== null,
    });

    const areMatchesLoading =
        matchQuery.isLoading ||
        midMatchQuery.isLoading ||
        btMatchQuery.isLoading;
    const areTournamentsLoading =
        midTournamentQuery.isLoading || btTournamentQuery.isLoading;

    const isLoading = areMatchesLoading || areTournamentsLoading;
    const match = matchQuery.data?.match ?? null;
    const midMatch = midMatchQuery.data?.match ?? null;
    const btMatch = btMatchQuery.data?.match ?? null;
    const targetMatch = level === "middle" ? midMatch : btMatch;
    const targetTournament = level === "middle" ? midTournament : btTournament;

    console.log(level);
    console.log(targetTournament);
    console.log(targetMatch);

    const hierarchyConfig: HierarchyConfig[] = buildHierarchy({
        level,
        match,
        midMatch,
        btMatch,
        params,
    });

    return (
        <Stack pt="lg" gap="lg">
            <Hierarchy hierarchyConfig={hierarchyConfig} />

            {isLoading ? (
                <ContainerSkeleton />
            ) : targetTournament !== null && targetMatch !== null ? (
                <MatchPage
                    tournament={targetTournament}
                    match={targetMatch}
                    now={nowUnixtime}
                />
            ) : (
                <NotFound>
                    <Stack gap={2} align="center">
                        <Title c="dimmed" fw="bold" order={3} ta="center">
                            We're not able to find details about match{" "}
                            <Text c="orange" inherit component="span">
                                {level === "middle"
                                    ? params.midMatchId
                                    : params.btMatchId}
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
