import { Breadcrumbs, Button, type BreadcrumbsProps } from "@mantine/core";
import type { FC } from "react";
import type { Match } from "../types";
import { MatchBadge } from "./MatchBadge";

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
            <Button
                key={levels[index]}
                component="a"
                variant="default"
                size="compact-xs"
                radius="xl"
            >
                {levels[index]}
            </Button>,
            <MatchBadge
                claim1={match.claim1}
                claim2={match.claim2}
                variant="default"
                size="compact-xs"
            />,
        ])
        .flat();

    items.push(
        <Button
            key={levels[parentMatches.length]}
            component="a"
            size="compact-xs"
            radius="xl"
        >
            {levels[parentMatches.length]}
        </Button>,
    );

    return (
        <Breadcrumbs separator="→" {...breadcrumbsProps}>
            {items}
        </Breadcrumbs>
    );
};
