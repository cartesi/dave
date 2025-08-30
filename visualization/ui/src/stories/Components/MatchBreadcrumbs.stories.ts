import type { Meta, StoryObj } from "@storybook/react-vite";
import { MatchBreadcrumbs } from "../../components/MatchBreadcrumbs";
import { claim } from "../util";

const meta = {
    title: "Components/Navigation/MatchBreadcrumbs",
    component: MatchBreadcrumbs,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof MatchBreadcrumbs>;

export default meta;
type Story = StoryObj<typeof meta>;

/**
 * Breadcrumbs for a bottom match.
 */
export const BottomMatch: Story = {
    args: {
        matches: [
            {
                claim1: claim(0),
                claim2: claim(1),
            },
            {
                claim1: claim(2),
                claim2: claim(3),
            },
            {
                claim1: claim(4),
                claim2: claim(5),
            },
        ],
        separatorMargin: 5,
    },
};

/**
 * Breadcrumbs for a middle match.
 */
export const MidMatch: Story = {
    args: {
        matches: [
            {
                claim1: claim(0),
                claim2: claim(1),
            },
            {
                claim1: claim(2),
                claim2: claim(3),
            },
        ],
    },
};

/**
 * Breadcrumbs for a top match.
 */
export const TopMatch: Story = {
    args: {
        matches: [
            {
                claim1: claim(0),
                claim2: claim(1),
            },
        ],
    },
};
