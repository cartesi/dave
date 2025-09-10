import type { FC } from "react";
import type { Match } from "../types";
import { MatchBadge, type MatchBadgeProps } from "./MatchBadge";

type MatchBreadcrumbSegmentProps = {
    match: Match;
    variant?: MatchBadgeProps["variant"];
};

export const MatchBreadcrumbSegment: FC<MatchBreadcrumbSegmentProps> = ({
    match,
    variant,
}) => {
    return (
        <MatchBadge
            claim1={match.claim1}
            claim2={match.claim2}
            size="compact-xs"
            variant={variant}
        />
    );
};
