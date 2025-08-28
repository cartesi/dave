import {
    Group,
    Progress,
    Stack,
    Text,
    useMantineTheme,
    type ProgressRootProps,
} from "@mantine/core";
import { useEffect, useState, type FC } from "react";
import type { CycleRange } from "../types";

interface RangeIndicatorProps extends Omit<ProgressRootProps, "value"> {
    /**
     * The domain of the range
     */
    domain: CycleRange;

    /**
     * The value of the range
     */
    value: CycleRange;

    /**
     * Whether to show the labels
     */
    withLabels?: boolean;
}

export const RangeIndicator: FC<RangeIndicatorProps> = (props) => {
    // color
    const theme = useMantineTheme();
    const color = props.color ?? theme.colors[theme.primaryColor][5];
    const bg = theme.colors.gray[2];

    const { domain, value, withLabels, ...progressProps } = props;
    const [start, end] = value;
    const [domainStart, domainEnd] = domain;

    const [width, setWidth] = useState(0);
    const [left, setLeft] = useState(0);

    useEffect(() => {
        // box percentage calculation
        setWidth((end - start) / (domainEnd - domainStart));
        setLeft((start - domainStart) / (domainEnd - domainStart));
    }, [domain, value]);

    return (
        <Stack gap={0}>
            {withLabels && (
                <Group gap="xs" justify="space-between">
                    <Text size="xs">{start}</Text>
                    <Text size="xs">{end}</Text>
                </Group>
            )}
            <Progress.Root {...progressProps}>
                <Progress.Section value={left * 100} color={bg} />
                <Progress.Section value={width * 100} color={color} />
            </Progress.Root>
        </Stack>
    );
};
