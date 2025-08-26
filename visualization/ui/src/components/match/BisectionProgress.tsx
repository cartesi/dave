import { Avatar, Group, Progress, Stack } from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import type { FC } from "react";
import { slice, zeroHash, type Hash } from "viem";
import type { Claim, CycleRange } from "../types";
import { RangeIndicator } from "./RangeIndicator";

interface BisectionProgressProps {
    /**
     * The range being bisected
     */
    range: CycleRange;

    /**
     * Maximum number of bisections to reach the target subdivision
     */
    max: number;

    /**
     * List of bisections. 0 is left, 1 is right
     */
    bisections: (0 | 1)[];

    /**
     * First claim
     */
    claim1: Claim;

    /**
     * Second claim
     */
    claim2: Claim;
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const BisectionProgress: FC<BisectionProgressProps> = (props) => {
    const { claim1, claim2, range, bisections, max } = props;

    // create ranges for each bisection
    const ranges = bisections.reduce(
        (r, bisection, i) => {
            const l = r[i];
            const mid = Math.floor((l[0] + l[1]) / 2);
            if (bisection === 0) {
                r.push([l[0], mid]);
                return r;
            } else {
                r.push([mid, l[1]]);
                return r;
            }
        },
        [range],
    );

    return (
        <Stack>
            <Group>
                <Avatar src={buildDataUrl(zeroHash)} size={24} opacity={0} />
                <Stack gap={3}>
                    <RangeIndicator
                        domain={range}
                        value={range}
                        withLabels
                        w={300}
                        h={16}
                    />
                    <Progress value={(bisections.length / max) * 100} />
                </Stack>
            </Group>
            {ranges.slice(1).map((r, i) => (
                <Group key={i}>
                    <Avatar
                        src={buildDataUrl(
                            i % 2 === 0 ? claim1.hash : claim2.hash,
                        )}
                        size={24}
                    />
                    <RangeIndicator
                        domain={range}
                        value={r}
                        withLabels
                        w={300}
                        h={16}
                    />
                </Group>
            ))}
        </Stack>
    );
};
