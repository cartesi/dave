import type { Meta, StoryObj } from "@storybook/react-vite";
import { BisectionProgress } from "../../components/match/BisectionProgress";

const meta = {
    title: "Components/BisectionProgress",
    component: BisectionProgress,
    parameters: {
        layout: "centered",
    },
} satisfies Meta<typeof BisectionProgress>;

export default meta;
type Story = StoryObj<typeof meta>;

const start = 14_837_880_065;
const end = 21_453_987_565;

export const Ongoing: Story = {
    args: {
        range: [start, end],
        bisections: [0, 1, 1, 0],
        max: 48,
    },
};

/**
 * A progress with no bisections yet
 */
export const NoBisections: Story = {
    args: {
        range: [start, end],
        bisections: [],
        max: 48,
    },
};

/**
 * Complete large bisection
 */
export const Complete: Story = {
    args: {
        range: [start, end],
        bisections: Array.from({ length: 48 }, () => 0),
        max: 48,
    },
};
