import { Badge, Breadcrumbs, type BreadcrumbsProps } from "@mantine/core";
import type { FC } from "react";
import { MatchBadge } from "./tournament/MatchBadge";
import type { Match } from "./types";

export interface MatchBreadcrumbsProps
    extends Omit<BreadcrumbsProps, "children"> {
    matches: Pick<Match, "claim1" | "claim2">[];
}

export const MatchBreadcrumbs: FC<MatchBreadcrumbsProps> = (props) => {
    const { matches, ...breadcrumbsProps } = props;
    const levels = ["top", "middle", "bottom"];

    // build the breadcrumb of the tournament hierarchy
    const items = matches
        .map((match, index) => [
            <Badge key={levels[index]} variant="default">
                {levels[index]}
            </Badge>,
            <MatchBadge
                key={index}
                claim1={match.claim1}
                claim2={match.claim2}
                variant={index === matches.length - 1 ? "filled" : "default"}
            />,
        ])
        .flat();

    return (
        <Breadcrumbs separator="→" {...breadcrumbsProps}>
            {items}
        </Breadcrumbs>
    );
};
