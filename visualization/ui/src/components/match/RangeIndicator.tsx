import {
    Group,
    Paper,
    Stack,
    Text,
    useMantineTheme,
    type PaperProps,
} from "@mantine/core";
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

    /**
     * Whether to show the labels
     */
    withLabels?: boolean;
}

export const RangeIndicator: FC<RangeIndicatorProps> = (props) => {
    // color
    const theme = useMantineTheme();
    const color = props.c ?? theme.primaryColor;

    const { domain, value, withLabels, ...paperProps } = props;
    const [start, end] = value;
    const [domainStart, domainEnd] = domain;

    // box percentage calculation
    const width = (end - start) / (domainEnd - domainStart);
    const left = (start - domainStart) / (domainEnd - domainStart);

    return (
        <Stack gap={0} w={paperProps.w}>
            {withLabels && (
                <Group gap="xs" justify="space-between">
                    <Text size="xs">{start}</Text>
                    <Text size="xs">{end}</Text>
                </Group>
            )}
            <Paper miw={32} withBorder {...paperProps} w="100%">
                <Paper
                    {...paperProps}
                    mih={8}
                    h="100%"
                    radius="xs"
                    left={`${left * 100}%`}
                    w={`${width * 100}%`}
                    pos="relative"
                    bg={color}
                ></Paper>
            </Paper>
        </Stack>
    );
};
