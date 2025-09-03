import {
    Button,
    type ButtonProps,
    type PolymorphicComponentProps,
} from "@mantine/core";
import type { FC } from "react";
import { HashAvatar } from "../HashAvatar";
import type { Claim } from "../types";

export type MatchBadgeProps = ButtonProps &
    PolymorphicComponentProps<
        "a",
        {
            /**
             * The first claim in the match.
             */
            claim1: Claim;

            /**
             * The second claim in the match.
             */
            claim2: Claim;
        }
    >;

const getAvatarSize = (size: ButtonProps["size"]) => {
    switch (size) {
        case "compact-xs":
            return 14;
        case "compact-sm":
            return 16;
        case "compact-md":
            return 20;
        case "compact-lg":
            return 24;
        case "compact-xl":
            return 28;
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

export const MatchBadge: FC<MatchBadgeProps> = (props) => {
    const { claim1, claim2, ...buttonProps } = props;
    const size = props.size ?? "compact-xs";
    const iconSize = getAvatarSize(size);
    const text = "vs";

    return (
        <Button
            component="a"
            radius="xl"
            leftSection={<HashAvatar hash={claim1.hash} size={iconSize} />}
            rightSection={<HashAvatar hash={claim2.hash} size={iconSize} />}
            variant="default"
            {...buttonProps}
            size={size}
        >
            {text}
        </Button>
    );
};
