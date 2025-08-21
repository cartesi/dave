import { Avatar, AvatarGroup, Group, Tooltip } from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import type { FC } from "react";
import { slice, type Hash } from "viem";
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
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const ClaimText: FC<ClaimTextProps> = ({
    claim,
    showParents = true,
    iconSize = 32,
    ...props
}) => {
    const parents = [];
    let parent = claim.parentClaim;
    while (parent) {
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
                <Avatar
                    key={parent.hash}
                    src={buildDataUrl(parent.hash)}
                    size={iconSize}
                />
            </Tooltip>,
        );
        parent = parent.parentClaim;
    }

    return (
        <Group gap="xs" wrap="nowrap">
            <AvatarGroup>
                {showParents && parents}
                <Avatar src={buildDataUrl(claim.hash)} size={iconSize} />
            </AvatarGroup>
            <LongText {...props} value={claim.hash} ff="monospace" />
        </Group>
    );
};
