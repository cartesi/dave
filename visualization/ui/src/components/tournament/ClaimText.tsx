import { AvatarGroup, Group, Tooltip } from "@mantine/core";
import type { FC } from "react";
import { HashAvatar } from "../HashAvatar";
import { LongText, type LongTextProps } from "../LongText";
import type { Claim } from "../types";

export interface ClaimTextProps extends Omit<LongTextProps, "value"> {
    /**
     * The claim to display.
     */
    claim: Claim;

    /**
     * The size of the avatar icons.
     */
    iconSize?: number;

    /**
     * Whether to show the parent claims.
     */
    showParents?: boolean;

    /**
     * Whether to show the avatar icons.
     */
    withIcon?: boolean;
}

export const ClaimText: FC<ClaimTextProps> = ({
    claim,
    showParents = true,
    iconSize = 32,
    withIcon = true,
    ...props
}) => {
    const parents = [];
    let parent = claim.parentClaim;
    while (parent && withIcon) {
        parents.unshift(
            <Tooltip
                key={parent.hash}
                label={
                    <LongText
                        value={parent.hash}
                        ff="monospace"
                        copyButton={false}
                    />
                }
            >
                <HashAvatar
                    key={parent.hash}
                    hash={parent.hash}
                    size={iconSize}
                />
            </Tooltip>,
        );
        parent = parent.parentClaim;
    }

    return (
        <Group gap="xs" wrap="nowrap">
            {withIcon && (
                <AvatarGroup>
                    {showParents && parents}
                    <HashAvatar hash={claim.hash} size={iconSize} />
                </AvatarGroup>
            )}
            <LongText {...props} value={claim.hash} ff="monospace" />
        </Group>
    );
};
