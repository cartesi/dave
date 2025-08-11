import { Container, Group, Stack, Text } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import ActionBar from "../../components/ActionBar";

const meta = {
  title: "Components/ActionBar",
  component: ActionBar,
  parameters: {
    layout: "padded",
  },
  tags: ["autodocs"],
} satisfies Meta<typeof ActionBar>;

export default meta;
type Story = StoryObj<typeof meta>;

type Props = Parameters<typeof ActionBar>[0];

const ActionBarInContainer = (props: Props) => {
  const { initialValue } = props;
  const [result, setResult] = useState(initialValue);
  return (
    <Container>
      <ActionBar {...props} onChange={(data) => setResult(data)} />
      <Stack gap={2} mt="lg">
        <Group gap={3}>
          <Text size="lg">Query:</Text>
          <Text fw="bold">{result.query ? result.query : "Empty"}</Text>
        </Group>
        <Group gap={3}>
          <Text size="lg">Order:</Text>
          <Text fw="bold">{result.sortingOrder}</Text>
        </Group>
      </Stack>
    </Container>
  );
};

export const Default: Story = {
  render: ActionBarInContainer,
  args: {
    initialValue: { query: "", sortingOrder: "ascending" },
    onChange(data) {
      alert(`Query: ${data.query}\nOrder:${data.sortingOrder}`);
    },
  },
};
