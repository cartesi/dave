import { Card, Overlay, useMantineTheme, type CardProps } from "@mantine/core";
import type { FC } from "react";
import type { CycleRange } from "../types";

interface RangeIndicatorProps extends CardProps {
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

    const { domain, value, ...cardProps } = props;
    const [start, end] = value;
    const [domainStart, domainEnd] = domain;

    // box percentage calculation
    const width = (end - start) / (domainEnd - domainStart);
    const left = start / (domainEnd - domainStart);

    return (
        <Card withBorder radius="md" miw={100} {...cardProps}>
            <Overlay
                bg={color}
                opacity={1.0}
                left={`${left * 100}%`}
                w={`${width * 100}%`}
            />
        </Card>
    );
};
