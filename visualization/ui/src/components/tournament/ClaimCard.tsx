import { Avatar, AvatarGroup, Group, Tooltip } from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import type { FC } from "react";
import { slice, type Hash } from "viem";
import { LongText, type LongTextProps } from "../LongText";
import type { Claim } from "../types";

export interface ClaimCardProps extends Omit<LongTextProps, "value"> {
    claim: Claim;
    parentClaims?: Claim[];
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const ClaimCard: FC<ClaimCardProps> = ({
    claim,
    parentClaims,
    ...props
}) => {
    return (
        <Group gap="xs" wrap="nowrap">
            <AvatarGroup>
                {parentClaims?.map((parentClaim) => (
                    <Tooltip
                        key={parentClaim.hash}
                        label={
                            <LongText
                                value={parentClaim.hash}
                                ff="monospace"
                                copyButton={false}
                            />
                        }
                    >
                        <Avatar
                            key={parentClaim.hash}
                            src={buildDataUrl(parentClaim.hash)}
                            size={32}
                        />
                    </Tooltip>
                ))}
                <Avatar src={buildDataUrl(claim.hash)} size={32} />
            </AvatarGroup>
            <LongText {...props} value={claim.hash} ff="monospace" />
        </Group>
    );
};
