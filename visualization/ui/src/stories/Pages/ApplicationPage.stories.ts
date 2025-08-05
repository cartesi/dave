import type { Meta, StoryObj } from "@storybook/react-vite";
import ListApplications from "../../features/application/ListApplications";

const meta = {
  title: "Pages/ListApplications",
  component: ListApplications,
  parameters: {
    // Optional parameter to center the component in the Canvas. More info: https://storybook.js.org/docs/configure/story-layout
    layout: "centered",
  },
} satisfies Meta<typeof ListApplications>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  args: {},
};
