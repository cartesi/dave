import { Stack } from "@mantine/core";
import type { FC } from "react";
import type { CycleRange } from "../types";
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
}

export const BisectionProgress: FC<BisectionProgressProps> = (props) => {
    const { range, bisections, max } = props;

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
        <Stack miw={240}>
            <RangeIndicator domain={range} value={range} withLabels />
            {ranges.slice(1).map((r, i) => (
                <RangeIndicator key={i} domain={range} value={r} withLabels />
            ))}
        </Stack>
    );
};
