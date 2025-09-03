import { Badge, Breadcrumbs, type BreadcrumbsProps } from "@mantine/core";
import type { FC } from "react";
import { MatchBadge } from "./tournament/MatchBadge";
import type { Match } from "./types";

export interface TournamentBreadcrumbsProps
    extends Omit<BreadcrumbsProps, "children"> {
    parentMatches: Pick<Match, "claim1" | "claim2">[];
}

export const TournamentBreadcrumbs: FC<TournamentBreadcrumbsProps> = (
    props,
) => {
    const { parentMatches, ...breadcrumbsProps } = props;
    const levels = ["top", "middle", "bottom"];

    // build the breadcrumb of the tournament hierarchy
    const items = parentMatches
        .map((match, index) => [
            <Badge key={levels[index]} variant="default">
                {levels[index]}
            </Badge>,
            <MatchBadge
                claim1={match.claim1}
                claim2={match.claim2}
                variant="default"
            />,
        ])
        .flat();

    items.push(
        <Badge key={levels[parentMatches.length]} variant="filled">
            {levels[parentMatches.length]}
        </Badge>,
    );

    return (
        <Breadcrumbs separator="→" {...breadcrumbsProps}>
            {items}
        </Breadcrumbs>
    );
};
