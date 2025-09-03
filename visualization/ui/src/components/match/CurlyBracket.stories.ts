import type { Meta, StoryObj } from "@storybook/react-vite";
import { CurlyBracket } from "./CurlyBracket";

const meta = {
    title: "Components/Match/CurlyBracket",
    component: CurlyBracket,
    argTypes: {
        tip: {
            control: {
                type: "range",
                min: 0,
                max: 1,
                step: 0.01,
            },
        },
    },
    tags: ["autodocs"],
} satisfies Meta<typeof CurlyBracket>;

export default meta;
type Story = StoryObj<typeof meta>;

/**
 * Default scenario
 */
export const Center: Story = {
    args: {
        h: 32,
        tip: 0.5,
    },
};

export const FirstQuarter: Story = {
    args: {
        h: 32,
        tip: 0.25,
    },
};

export const Start: Story = {
    args: {
        h: 32,
        tip: 0,
    },
};

export const End: Story = {
    args: {
        h: 32,
        tip: 1,
    },
};
