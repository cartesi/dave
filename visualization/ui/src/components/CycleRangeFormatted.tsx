import { Text, type TextProps } from "@mantine/core";
import type { FC } from "react";
import type { CycleRange } from "./types";

const mcycleFormatter = new Intl.NumberFormat("en-US", {});

interface CycleRangeFormattedProps extends TextProps {
    cycleRange: CycleRange;
}

export const CycleRangeFormatted: FC<CycleRangeFormattedProps> = ({
    cycleRange,
    ...textProps
}) => {
    const [startCycle, endCycle] = cycleRange;
    const formattedText = `${mcycleFormatter.format(startCycle)} → ${mcycleFormatter.format(endCycle)}`;

    return <Text {...textProps}>{formattedText}</Text>;
};
