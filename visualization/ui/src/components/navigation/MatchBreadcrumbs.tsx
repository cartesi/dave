import { Breadcrumbs, Button, type BreadcrumbsProps } from "@mantine/core";
import type { FC } from "react";
import type { Match } from "../types";
import { MatchBadge } from "./MatchBadge";

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
                key={index}
                claim1={match.claim1}
                claim2={match.claim2}
                size="compact-xs"
                variant={index === matches.length - 1 ? undefined : "default"}
            />,
        ])
        .flat();

    return (
        <Breadcrumbs separator="→" {...breadcrumbsProps}>
            {items}
        </Breadcrumbs>
    );
};
