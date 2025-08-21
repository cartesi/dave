import { Avatar, Group, Text, Tooltip, type GroupProps } from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import type { FC } from "react";
import { slice, type Hash } from "viem";
import type { Match } from "../types";

export interface MatchMiniProps extends GroupProps {
    /**
     * The match to display.
     */
    match: Match;
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

const shorten = (value: string, sliceSize = 4, pad = 2) =>
    value
        .slice(0, sliceSize + pad)
        .concat("...")
        .concat(value.slice(-sliceSize));

export const MatchMini: FC<MatchMiniProps> = ({ match, ...groupProps }) => {
    const { claim1, claim2 } = match;

    return (
        <Group gap="xs" {...groupProps}>
            <Tooltip label={shorten(claim1.hash)}>
                <Avatar src={buildDataUrl(claim1.hash)} size={22} />
            </Tooltip>
            <Text style={{ textAlign: "center" }}>vs</Text>
            <Tooltip label={shorten(claim2.hash)}>
                <Avatar src={buildDataUrl(claim2.hash)} size={22} />
            </Tooltip>
        </Group>
    );
};
