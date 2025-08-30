import { Text, type TextProps } from "@mantine/core";
import type { FC } from "react";
import type { CycleRange } from "./types";

const formatter = new Intl.NumberFormat("en-US", {});

interface CycleRangeFormattedProps extends TextProps {
    range: CycleRange;
}

export const CycleRangeFormatted: FC<CycleRangeFormattedProps> = ({
    range,
    ...textProps
}) => {
    const [start, end] = range;
    const formattedText = `${formatter.format(start)} → ${formatter.format(end)}`;
    return <Text {...textProps}>{formattedText}</Text>;
};
