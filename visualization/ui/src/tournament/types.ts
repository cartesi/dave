import {
  MatchStatus,
  type TournamentFilter,
} from "../generated/graphql/graphql";

type PagingBefore = {
  before: string;
  after?: never;
};

type PagingAfter = {
  after: string;
  before?: never;
};

export type Paging = PagingAfter | PagingBefore;

export interface TournamentsQueryParams {
  where?: TournamentFilter;
  paging?: Paging;
}

export const TournamentStatus = {
  ...MatchStatus,
  created: "CREATED",
} as const;
