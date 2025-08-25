import { Badge, Breadcrumbs, type BreadcrumbsProps } from "@mantine/core";
import type { FC, ReactNode } from "react";
import { MatchBadge } from "./tournament/MatchBadge";
import type { Tournament } from "./types";

export interface TournamentBreadcrumbsProps
    extends Omit<BreadcrumbsProps, "children"> {
    tournament: Pick<Tournament, "level" | "parentMatch">;
}

export const TournamentBreadcrumbs: FC<TournamentBreadcrumbsProps> = ({
    tournament,
    ...breadcrumbsProps
}) => {
    let { level, parentMatch } = tournament;

    // build the breadcrumb of the tournament hierarchy
    const parents: ReactNode[] = [];
    while (parentMatch) {
        parents.unshift(<MatchBadge match={parentMatch} />);
        parents.unshift(
            <Badge key={parentMatch.parentTournament.level} variant="default">
                {parentMatch.parentTournament.level}
            </Badge>,
        );
        parentMatch = parentMatch.parentTournament.parentMatch;
    }

    return (
        <Breadcrumbs separator="→" {...breadcrumbsProps}>
            {parents}
            <Badge key={level}>{level}</Badge>
        </Breadcrumbs>
    );
};
