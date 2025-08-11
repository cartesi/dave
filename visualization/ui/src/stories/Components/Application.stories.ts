import type { Meta, StoryObj } from "@storybook/react-vite";
import { ApplicationCard } from "../../components/application/Application";
import { HoneypotDapp } from "../../components/application/application.mocks";

const meta = {
  title: "Components/Application",
  component: ApplicationCard,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof ApplicationCard>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Enabled: Story = {
  args: { application: HoneypotDapp },
};

export const Disabled: Story = {
  args: { application: { ...HoneypotDapp, state: "DISABLED" } },
};

export const Inoperable: Story = {
  args: { application: { ...HoneypotDapp, state: "INOPERABLE" } },
};
