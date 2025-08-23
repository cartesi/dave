import {
    Box,
    Group,
    Stack,
    Text,
    useMantineColorScheme,
    type MantineColor,
} from "@mantine/core";
import * as d3 from "d3";
import { useEffect, useMemo, useRef, useState, type FC } from "react";
import useRightColorShade from "../../hooks/useRightColorShade";
import type { Cycle, CycleRange } from "../types";

const ZERO = 0n as const;
const ONE_HUNDRED = 100n as const;

function getLengthInPixel(limitBoundLength: Cycle, endpointLength: Cycle) {
    if (!limitBoundLength || limitBoundLength === ZERO) return ZERO;

    return (endpointLength * ONE_HUNDRED) / limitBoundLength;
}

function convertIntervalToPixels(
    lowerBound: Cycle,
    upperBound: Cycle,
    start: Cycle,
    end: Cycle,
): CycleRange {
    const length = upperBound - lowerBound;
    const startLength = start - lowerBound;
    const endLength = length - (upperBound - end);

    const leftEndpoint = getLengthInPixel(length, startLength);
    const rightEndpoint = getLengthInPixel(length, endLength);

    return [leftEndpoint, rightEndpoint];
}

function isWithinLimits(limits: CycleRange, interval: CycleRange): boolean {
    const [lowerBound, upperBound] = limits;
    const [left, right] = interval;

    return left >= lowerBound && right <= upperBound;
}

type DrawBarParams = {
    containerEl: HTMLDivElement;
    config?: {
        baseColor: MantineColor;
        intervalColor: MantineColor;
        baseRadius: number;
    };
};
type GraphData = {
    leftEndpoint: number;
    rightEndpoint: number;
    color: MantineColor;
};

function drawBar({ containerEl, config }: DrawBarParams) {
    const containerWidth = containerEl.offsetWidth;
    const svgHeight = containerEl.offsetHeight;
    const margin = { top: 0, right: 0, bottom: 0, left: 0 };
    const width = containerWidth - margin.left - margin.right;
    const height = svgHeight - margin.top - margin.bottom;
    const baseColor = config?.baseColor ?? "lightgray";
    const baseRadius = config?.baseRadius ?? 5;
    const intervalColor = config?.intervalColor ?? "green";
    const transitionDuration = 750;

    const svg = d3
        .select(containerEl)
        .append("svg")
        .attr("width", containerWidth)
        .attr("height", svgHeight);

    const g = svg
        .append("g")
        .attr("transform", `translate(${margin.left}, ${margin.top})`);

    const xScale = d3.scaleLinear().domain([0, 100]).range([0, width]);

    g.append("rect")
        .attr("x", 0)
        .attr("y", 0)
        .attr("class", "graph-base")
        .attr("width", width)
        .attr("height", height)
        .attr("fill", baseColor)
        .attr("rx", baseRadius)
        .attr("ry", baseRadius);

    return {
        remove() {
            svg.remove();
        },
        drawInterval(interval: CycleRange) {
            const data = [
                {
                    leftEndpoint: Number(interval[0]),
                    rightEndpoint: Number(interval[1]),
                    color: intervalColor,
                },
            ];

            g.selectAll(".overlay-bisection")
                .data(data)
                .enter()
                .append("rect")
                .attr("class", "overlay-bisection")
                .attr("x", (d) => xScale(d.leftEndpoint))
                .attr("y", 0)
                .attr(
                    "width",
                    (d) => xScale(d.rightEndpoint) - xScale(d.leftEndpoint),
                )
                .attr("height", height)
                .attr("fill", (d) => d.color)
                .attr("rx", baseRadius)
                .attr("ry", baseRadius);
        },

        updateInterval(interval: CycleRange) {
            const data = [
                {
                    leftEndpoint: Number(interval[0]),
                    rightEndpoint: Number(interval[1]),
                    color: intervalColor,
                },
            ];

            g.selectAll(".overlay-bisection")
                .data(data)
                .transition()
                .duration(transitionDuration)
                .attr("x", (d) => xScale(d.leftEndpoint))
                .attr(
                    "width",
                    (d) => xScale(d.rightEndpoint) - xScale(d.leftEndpoint),
                );
        },
        updateColors(baseColor: MantineColor, intervalColor: MantineColor) {
            g.select(".graph-base")
                .transition()
                .duration(transitionDuration)
                .style("fill", baseColor);
            g.select(".overlay-bisection")
                .transition()
                .duration(transitionDuration)
                .style("fill", intervalColor);
        },
        onResize(newContainerWidth: number) {
            const newWidth = newContainerWidth - margin.left - margin.right;

            xScale.range([0, newWidth]);
            svg.attr("width", newContainerWidth);
            g.select("rect:nth-child(1)").attr("width", newWidth);

            g.selectAll<SVGRectElement, GraphData>(".overlay-bisection")
                .attr("x", (d) => xScale(d.leftEndpoint))
                .attr(
                    "width",
                    (d) => xScale(d.rightEndpoint) - xScale(d.leftEndpoint),
                );
        },
    };
}

function updateScaleOnResize(instance: BarGraphInstance, el: HTMLDivElement) {
    const resizeObserver = new ResizeObserver((entries) => {
        for (const entry of entries) {
            const { width } = entry.contentRect;
            instance.onResize(width);
        }
    });
    resizeObserver.observe(el);
    // Clean up
    return () => {
        resizeObserver.unobserve(el);
        resizeObserver.disconnect();
    };
}

type BarGraphInstance = ReturnType<typeof drawBar>;

type Props = {
    cycleLimits: CycleRange;
    cycleRange: CycleRange;
    width?: number | string;
    height?: number | string;
};

const CycleRangeGraph: FC<Props> = ({
    cycleLimits,
    cycleRange,
    width = "inherit",
    height = 21,
}) => {
    const divRef = useRef<HTMLDivElement>(null);
    const [instance, setInstance] = useState<BarGraphInstance | null>(null);
    const [lowerBound, upperBound] = cycleLimits;
    const [cycleStart, cycleEnd] = cycleRange;
    const { colorScheme } = useMantineColorScheme();
    const mainColor =
        colorScheme === "auto" || colorScheme === "light" ? "green" : "cyan";
    const baseColor = useRightColorShade("gray");
    const intervalColor = useRightColorShade(mainColor);
    const interval = useMemo(() => {
        return convertIntervalToPixels(
            lowerBound,
            upperBound,
            cycleStart,
            cycleEnd,
        );
    }, [lowerBound, upperBound, cycleStart, cycleEnd]);

    const isWithinLimitBounds = useMemo(() => {
        return isWithinLimits([lowerBound, upperBound], [cycleStart, cycleEnd]);
    }, [lowerBound, upperBound, cycleStart, cycleEnd]);

    useEffect(() => {
        if (divRef.current !== null) {
            console.info("bootstrapping...");
            const instance = drawBar({
                containerEl: divRef.current,
                config: { baseColor, intervalColor, baseRadius: 5 },
            });
            setInstance(instance);
            const dispose = updateScaleOnResize(instance, divRef.current);

            return () => {
                console.info(
                    "Cleaning. Removing instance, disposing resize-event-listener and setting instance state to null.",
                );
                setInstance(null);
                dispose();
                instance.remove();
            };
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    useEffect(() => {
        if (instance !== null) {
            console.info("drawing interval...");
            instance.drawInterval(interval);
        }
    }, [interval, instance]);

    useEffect(() => {
        if (instance !== null) {
            console.info("updating color...");
            instance.updateColors(baseColor, intervalColor);
        }
    }, [colorScheme, baseColor, intervalColor, instance]);

    if (!isWithinLimitBounds)
        return (
            <Stack gap="0" align="flex-end">
                <Group justify="flex-end">
                    <Text fw="bold" c="red">
                        Cycle range is not within the cycle limits
                    </Text>
                </Group>
                <Text size="xs" c="dimmed">
                    Cycle Limits: {cycleLimits.join(" - ")}
                </Text>
                <Text size="xs" c="dimmed">
                    Cycle Interval: {cycleRange.join(" - ")}
                </Text>
            </Stack>
        );

    return <Box ref={divRef} component="div" h={height} w={width}></Box>;
};

export default CycleRangeGraph;
