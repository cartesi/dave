import { Paper, useMantineTheme, type PaperProps } from "@mantine/core";
import type { FC } from "react";
import type { CycleRange } from "../types";

interface RangeIndicatorProps extends PaperProps {
    /**
     * The domain of the range
     */
    domain: CycleRange;
    /**
     * The value of the range
     */
    value: CycleRange;
}

export const RangeIndicator: FC<RangeIndicatorProps> = (props) => {
    // color
    const theme = useMantineTheme();
    const color = props.c ?? theme.primaryColor;

    const { domain, value, ...paperProps } = props;
    const [start, end] = value;
    const [domainStart, domainEnd] = domain;

    // box percentage calculation
    const width = (end - start) / (domainEnd - domainStart);
    const left = (start - domainStart) / (domainEnd - domainStart);

    return (
        <Paper miw={32} withBorder {...paperProps}>
            <Paper
                mih={8}
                left={`${left * 100}%`}
                w={`${width * 100}%`}
                pos="relative"
                {...paperProps}
                bg={color}
            ></Paper>
        </Paper>
    );
};
