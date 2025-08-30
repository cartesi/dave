import { Badge, type BadgeProps } from "@mantine/core";
import type { FC } from "react";
import { HashAvatar } from "../HashAvatar";
import type { Match } from "../types";

export interface MatchBadgeProps extends BadgeProps {
    /**
     * The match to display.
     */
    match: Pick<Match, "claim1" | "claim2">;
}

const getAvatarOffset = (size: BadgeProps["size"]) => {
    switch (size) {
        case "xs":
            return "-5px";
        case "sm":
            return "-7px";
        case "md":
            return "-8px";
        case "lg":
            return "-10px";
        case "xl":
            return "-14px";
        default:
            return "-8px";
    }
};

const getAvatarSize = (size: BadgeProps["size"]) => {
    switch (size) {
        case "xs":
            return 12;
        case "sm":
            return 14;
        case "md":
            return 16;
        case "lg":
            return 21;
        case "xl":
            return 26;
        default:
            return 16;
    }
};

export const MatchBadge: FC<MatchBadgeProps> = ({ match, ...badgeProps }) => {
    const { claim1, claim2 } = match;
    const iconSize = getAvatarSize(badgeProps.size);
    const offset = getAvatarOffset(badgeProps.size);
    const text = "vs";

    return (
        <Badge
            leftSection={
                <HashAvatar hash={claim1.hash} size={iconSize} left={offset} />
            }
            rightSection={
                <HashAvatar hash={claim2.hash} size={iconSize} right={offset} />
            }
            variant="default"
            {...badgeProps}
        >
            {text}
        </Badge>
    );
};
