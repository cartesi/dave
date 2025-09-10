import { Badge, type BadgeVariant } from "@mantine/core";
import type { FC } from "react";
import type { Tournament } from "../types";

type TournamentBreadcrumbSegmentProps = {
    level: Tournament["level"];
    variant?: BadgeVariant;
};

export const TournamentBreadcrumbSegment: FC<
    TournamentBreadcrumbSegmentProps
> = ({ level, variant }) => {
    return (
        <Badge radius="xl" variant={variant}>
            {level}
        </Badge>
    );
};
