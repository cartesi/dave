import { Box, type BoxProps } from "@mantine/core";
import { useElementSize } from "@mantine/hooks";
import type { FC } from "react";

type CurlyBracketProps = Omit<BoxProps, "children"> & {
    /**
     * The horizontal position of the tip (0–1 ratio).
     */
    tip?: number;

    /**
     * The radius of the curve at the ends and tip.
     */
    radius?: number;

    /**
     * The radius of the curve at the pointer.
     */
    pointerRadius?: number;

    /**
     * The stroke width.
     */
    strokeWidth?: number;

    /**
     * The stroke color.
     */
    color?: string;
};

export const CurlyBracket: FC<CurlyBracketProps> = (props) => {
    const {
        tip = 0.5, // default in the middle (50%)
        strokeWidth = 2,
        color = "gray",
        pointerRadius,
        radius,
        ...boxProps
    } = props;

    // use element size to get the width and height of the bracket
    const { height, ref, width } = useElementSize();

    const x0 = strokeWidth / 2;
    const x1 = width - strokeWidth / 2;

    // border radius, default to 65% of the height
    const r = radius ?? height * 0.65;

    // pointer radius, default to height minus the border radius
    const p = pointerRadius ?? height - r;

    // calculate the tip position in pixels
    const t = tip * width;

    // Path: left rounded end → line → tip → line → right rounded end
    const path = `
    M ${x0} ${height}
    V ${p + r}
    Q ${x0} ${p} ${r} ${p}
    H ${t - p}
    Q ${t} ${p} ${t} 0
    Q ${t} ${p} ${t + p} ${p}
    H ${x1 - r}
    Q ${x1} ${p} ${x1} ${p + r}
    V ${height}
  `;

    return (
        <Box ref={ref} {...boxProps}>
            <svg
                width={width}
                height={height}
                viewBox={`0 0 ${width} ${height}`}
                style={{ display: "block" }}
            >
                <path
                    d={path}
                    stroke={color}
                    strokeWidth={strokeWidth}
                    fill="none"
                />
            </svg>
        </Box>
    );
};
