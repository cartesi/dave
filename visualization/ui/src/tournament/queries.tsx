import { useQuery } from "@tanstack/react-query";
import request from "graphql-request";
import { graphql } from "../generated/graphql";
import { graphqlUrl } from "../lib/config";
import type { UnfoldDocumentNodeQuery } from "../lib/types";
import { TournamentStatus, type TournamentsQueryParams } from "./types";

const ListTournamentQuery = graphql(`
  query ListTopTournament(
    $limit: Int!
    $orderBy: String
    $direction: String
    $where: TournamentFilter
    $after: String
    $before: String
  ) {
    tournaments(
      limit: $limit
      orderBy: $orderBy
      orderDirection: $direction
      where: $where
      after: $after
      before: $before
    ) {
      pageInfo {
        hasNextPage
        hasPreviousPage
        startCursor
        endCursor
      }
      totalCount
      items {
        id
        timestamp
        level
        startedMatches: matches(where: { status: STARTED }) {
          totalCount
        }
        finishedMatches: matches(where: { status: FINISHED }) {
          totalCount
        }
        commitments {
          totalCount
        }
      }
    }
  }
`);

type TournamentQueryReturn = UnfoldDocumentNodeQuery<
  typeof ListTournamentQuery
>;
type Tournament = TournamentQueryReturn["tournaments"]["items"][number];

const getSummary = (tournament: Tournament) => {
  const startedMatches = tournament.startedMatches?.totalCount ?? 0;
  const finishedMatches = tournament.finishedMatches?.totalCount ?? 0;
  const totalMatches = startedMatches + finishedMatches;

  if (totalMatches === 0)
    return { totalMatches, status: TournamentStatus.created };
  if (startedMatches > 0)
    return { totalMatches, status: TournamentStatus.Started };

  return { totalMatches, status: TournamentStatus.Finished };
};

const fetchTournaments = async (params: TournamentsQueryParams) => {
  const paging = params.paging;
  const where = params.where;
  const optionals = {
    ...paging,
    where,
  };

  const { tournaments } = await request(graphqlUrl, ListTournamentQuery, {
    limit: 5,
    direction: "desc",
    orderBy: "timestamp",
    ...optionals,
  });

  const { items, totalCount, pageInfo } = tournaments;

  const parsedItems = items.map((tournament) => {
    const summary = getSummary(tournament);

    return {
      id: tournament.id,
      timestamp: parseInt(tournament.timestamp) * 1000,
      level: parseInt(tournament.level ?? 0),
      status: summary.status,
      totalMatches: summary.totalMatches,
      totalCommitments: tournament.commitments?.totalCount ?? 0,
    };
  });

  return {
    totalCount,
    tournaments: parsedItems,
    pageInfo,
  };
};

// HOOKS & REACT_QUERY KEYS

export const tournamentKeys = {
  base: ["tournaments"] as const,
  lists: () => [...tournamentKeys.base, "list"] as const,
  paginated: (cursor: string) => [...tournamentKeys.lists(), cursor] as const,
  detail: (id: string) => [...tournamentKeys.base, id] as const,
};

export const useTournamentList = (params: TournamentsQueryParams = {}) => {
  const cursor = params.paging?.before ?? params.paging?.after ?? "no-cursor";

  return useQuery({
    queryKey: tournamentKeys.paginated(cursor),
    queryFn: () => fetchTournaments(params),
    refetchInterval: 5000,
    refetchIntervalInBackground: true,
  });
};
