import { Avatar, Group } from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import type { FC } from "react";
import { slice, type Hash } from "viem";
import { LongText, type LongTextProps } from "../LongText";
import type { Claim } from "../types";

export interface ClaimCardProps extends Omit<LongTextProps, "value"> {
    claim: Claim;
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const ClaimCard: FC<ClaimCardProps> = ({ claim, ...props }) => {
    // generate a jazzicon
    const avatar = buildDataUrl(claim.hash);

    return (
        <Group gap="xs" wrap="nowrap">
            <Avatar src={avatar} size={24} />
            <LongText {...props} value={claim.hash} ff="monospace" />
        </Group>
    );
};
