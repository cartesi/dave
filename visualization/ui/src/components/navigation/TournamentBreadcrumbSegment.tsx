import { Button, type ButtonVariant } from "@mantine/core";
import type { FC } from "react";
import type { Tournament } from "../types";

type TournamentBreadcrumbSegmentProps = {
    level: Tournament["level"];
    variant?: ButtonVariant;
};

export const TournamentBreadcrumbSegment: FC<
    TournamentBreadcrumbSegmentProps
> = ({ level, variant }) => {
    return (
        <Button
            component="span"
            variant={variant}
            size="compact-xs"
            radius="xl"
            data-id={`tournament-${level}`}
        >
            {level}
        </Button>
    );
};
