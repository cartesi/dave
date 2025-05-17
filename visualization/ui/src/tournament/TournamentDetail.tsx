import type { ResultOf } from "@graphql-typed-document-node/core";
import { useQuery } from "@tanstack/react-query";
import request from "graphql-request";
import type { FC } from "react";
import { useParams } from "react-router";
import { graphql } from "../generated/graphql";
import type {
  CommitmentStatus,
  MatchStatus,
} from "../generated/graphql/graphql";
import { graphqlUrl } from "../lib/config";
import type { UnfoldDocumentNodeQuery } from "../lib/types";
import { timestampToMillis } from "../lib/utils";
import { tournamentKeys } from "./queries";

// eslint-disable-next-line @typescript-eslint/no-unused-vars
const CommitmentItemFragment = graphql(`
  fragment CommitmentItem on Commitment {
    id
    commitmentHash
    status
    machineHash
    proof
    playerAddress
    lNode
    rNode
    timestamp
  }
`);

// eslint-disable-next-line @typescript-eslint/no-unused-vars
const MatchItemFragment = graphql(`
  fragment MatchItem on Match {
    id
    commitmentOne
    commitmentTwo
    status
    leftOfTwo
    timestamp
    tournament {
      id
    }
  }
`);

const TournamentDetailQuery = graphql(`
  query TournamentDetail($id: String!) {
    tournament(id: $id) {
      id
      level
      matches(limit: 3, orderBy: "timestamp", orderDirection: "desc") {
        items {
          ...MatchItem
        }
      }

      commitments(limit: 3, orderBy: "timestamp", orderDirection: "desc") {
        items {
          ...CommitmentItem
        }
      }

      innerTournaments(limit: 3) {
        items {
          id
          level
          matches(limit: 3, orderBy: "timestamp", orderDirection: "desc") {
            items {
              ...MatchItem
            }
          }

          commitments(limit: 3, orderBy: "timestamp", orderDirection: "desc") {
            items {
              ...CommitmentItem
            }
          }
        }
      }
    }
  }
`);

type CommitmentItem = ResultOf<typeof CommitmentItemFragment>;
type MatchItem = ResultOf<typeof MatchItemFragment>;
type Tournament = UnfoldDocumentNodeQuery<
  typeof TournamentDetailQuery
>["tournament"];

const parseMatch = (match: MatchItem) => {
  return {
    id: match.id,
    commitmentOne: match.commitmentOne,
    commitmentTwo: match.commitmentTwo,
    status: match.status as MatchStatus,
    leftOfTwo: match.leftOfTwo,
    timestamp: timestampToMillis(match.timestamp),
    fromTournament: match.tournament?.id,
  };
};

const parseCommitment = (commitment: CommitmentItem) => {
  return {
    id: commitment.id,
    commitmentHash: commitment.commitmentHash,
    playerAddress: commitment.playerAddress,
    status: commitment.status as CommitmentStatus,
    timestamp: timestampToMillis(commitment.timestamp),
    input: {
      proof: commitment.proof as string[],
      machineHash: commitment.machineHash,
      lNode: commitment.lNode,
      rNode: commitment.rNode,
    },
  };
};

interface TournamentDetail {
  id: string;
  level: number;
  commitments: ReturnType<typeof parseCommitment>[];
  matches: ReturnType<typeof parseMatch>[];
  innerTournaments: TournamentDetail[];
}

const parseTournament = (detail: NonNullable<Tournament>): TournamentDetail => {
  const level = parseInt(detail.level ?? 0);
  const commitments =
    (detail.commitments?.items as CommitmentItem[]).map(parseCommitment) ?? [];
  const matches = (detail.matches?.items as MatchItem[]).map(parseMatch) ?? [];
  const innerTournaments =
    detail.innerTournaments?.items.map(parseTournament) ?? [];

  return {
    id: detail.id,
    level,
    matches,
    commitments,
    innerTournaments,
  };
};

const fetchDetails = async (id: string) => {
  const { tournament } = await request(graphqlUrl, TournamentDetailQuery, {
    id,
  });

  if (!tournament) return { tournamentDetail: null };

  const tournamentDetail = parseTournament(tournament);

  return { tournamentDetail };
};

interface HookParams {
  id: string;
}

const useTournamentDetail = (params: HookParams) => {
  return useQuery({
    queryKey: tournamentKeys.detail(params.id),
    queryFn: () => fetchDetails(params.id),
    refetchInterval: 5000,
    refetchIntervalInBackground: true,
  });
};

const TournamentDetail: FC = () => {
  const { id } = useParams();

  return (
    <h1 className="text-xl font-semibold text-secondary">
      Tournament Detail {id}
    </h1>
  );
};

export default TournamentDetail;
