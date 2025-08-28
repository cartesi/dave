import { Badge, Breadcrumbs, type BreadcrumbsProps } from "@mantine/core";
import type { FC, ReactNode } from "react";
import { MatchBadge } from "./tournament/MatchBadge";
import type { Match, Tournament } from "./types";

export interface MatchBreadcrumbsProps
    extends Omit<BreadcrumbsProps, "children"> {
    match: Match;
}

export const MatchBreadcrumbs: FC<MatchBreadcrumbsProps> = ({
    match,
    ...breadcrumbsProps
}) => {
    // build the breadcrumb of the tournament hierarchy
    let parentTournament: Tournament | undefined = match.parentTournament;
    const parents: ReactNode[] = [];
    while (parentTournament) {
        parents.unshift(
            <Badge key={parentTournament.level} variant="default">
                {parentTournament.level}
            </Badge>,
        );
        if (parentTournament.parentMatch) {
            parents.unshift(
                <MatchBadge match={parentTournament.parentMatch} />,
            );
        }
        parentTournament = parentTournament.parentMatch?.parentTournament;
    }

    return (
        <Breadcrumbs separator="→" {...breadcrumbsProps}>
            {parents}
            <MatchBadge match={match} variant="filled" />
        </Breadcrumbs>
    );
};
