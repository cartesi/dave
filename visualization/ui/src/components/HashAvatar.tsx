import { Avatar, type AvatarProps } from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import { useMemo, type FC } from "react";
import type { Hash } from "viem";
import { slice } from "viem";

export interface HashAvatarProps extends Omit<AvatarProps, "src"> {
    /**
     * The hash to represent..
     */
    hash: Hash;
}

const buildDataUrl = (hash: Hash): string =>
    `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;

export const HashAvatar: FC<HashAvatarProps> = ({ hash, ...props }) => {
    const src = useMemo(() => buildDataUrl(hash), [hash]);
    return <Avatar src={src} {...props} />;
};
