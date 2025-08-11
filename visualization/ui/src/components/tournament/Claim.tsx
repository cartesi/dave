import { Center, Overlay, Stack, Text, type TextProps } from "@mantine/core";
import { useClipboard } from "@mantine/hooks";
import type { FC } from "react";
import type { Claim } from "../types";

export interface ClaimCardProps extends TextProps {
    claim: Claim;
}

export const ClaimCard: FC<ClaimCardProps> = ({ claim, ...props }) => {
    const clipboard = useClipboard({ timeout: 500 });
    const l1 = claim.hash.slice(2, 18);
    const l2 = claim.hash.slice(18, 34);
    const l3 = claim.hash.slice(34, 50);
    const l4 = claim.hash.slice(50, 66);
    const bg = "white"; // TODO: this should be the theme default bg color
    return (
        <Stack
            gap={0}
            onClick={() => clipboard.copy(claim)}
            style={{ cursor: "pointer" }}
            pos="relative"
        >
            {clipboard.copied && (
                <Overlay opacity={1} bg={bg}>
                    <Stack h="100%" justify="center">
                        <Center>
                            <Text>copied</Text>
                        </Center>
                    </Stack>
                </Overlay>
            )}
            <Text ff="monospace" {...props}>
                {l1}
            </Text>
            <Text ff="monospace" {...props}>
                {l2}
            </Text>
            <Text ff="monospace" {...props}>
                {l3}
            </Text>
            <Text ff="monospace" {...props}>
                {l4}
            </Text>
        </Stack>
    );
};
