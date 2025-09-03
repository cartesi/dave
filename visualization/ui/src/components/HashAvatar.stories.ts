import type { Meta, StoryObj } from "@storybook/react-vite";
import { zeroHash } from "viem";
import { HashAvatar } from "./HashAvatar";

/**
 * HashAvatar component used to visually represent a hash value using an Avatar component and a jazzicon.
 * It's especially useful when there are several hashes to display in a single screen and you want to help the user to distinguish them or match equals values.
 */
const meta = {
    title: "Components/General/HashAvatar",
    component: HashAvatar,
    tags: ["autodocs"],
} satisfies Meta<typeof HashAvatar>;

export default meta;
type Story = StoryObj<typeof meta>;

/**
 * Example with default values
 */
export const Default: Story = {
    args: { hash: zeroHash },
};

/**
 * Example with sm size
 */
export const Small: Story = {
    args: { hash: zeroHash, size: "sm" },
};

/**
 * Example with xs size
 */
export const ExtraSmall: Story = {
    args: { hash: zeroHash, size: "xs" },
};

/**
 * Example with lg size
 */
export const Large: Story = {
    args: { hash: zeroHash, size: "lg" },
};

/**
 * Example with xl size
 */
export const ExtraLarge: Story = {
    args: { hash: zeroHash, size: "xl" },
};
