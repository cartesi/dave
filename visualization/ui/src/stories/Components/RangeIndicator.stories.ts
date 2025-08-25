import type { Meta, StoryObj } from "@storybook/react-vite";
import { RangeIndicator } from "../../components/match/RangeIndicator";

const meta = {
    title: "Components/RangeIndicator",
    component: RangeIndicator,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof RangeIndicator>;

export default meta;
type Story = StoryObj<typeof meta>;

/**
 * Indicator for the full range
 */
export const Full: Story = {
    args: { domain: [0, 100], value: [0, 100] },
};

/**
 * Indicator for first half
 */
export const FirstHalf: Story = {
    args: { domain: [0, 100], value: [0, 50] },
};

/**
 * Indicator for second half
 */
export const SecondHalf: Story = {
    args: { domain: [0, 100], value: [50, 100] },
};

/**
 * Indicator for empty range
 */
export const Empty: Story = {
    args: { domain: [0, 100], value: [0, 0] },
};

/**
 * Indicator for second quarter
 */
export const SecondQuarter: Story = {
    args: { domain: [0, 100], value: [25, 50] },
};

/**
 * Indicator for large domain value with a small range
 */
const start = 1837880065;
const end = 2453987565;
const step = (end - start) / 16;
export const LargeDomain: Story = {
    args: { domain: [start, end], value: [start + step * 8, start + step * 9] },
};

/**
 * RealValue
 */
export const RealValue: Story = {
    args: { domain: [start, end], value: [start, (start + end) / 2] },
};

/**
 * Different color. Use the `c` prop to change the color.
 */
export const ForegroundColor: Story = {
    args: { domain: [0, 100], value: [0, 50], c: "green" },
};

/**
 * Different background. Use the `bg` prop to change the background color.
 */
export const BackgroundColor: Story = {
    args: { domain: [0, 100], value: [0, 50], bg: "lightgray" },
};
