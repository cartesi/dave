import {
  Button,
  Group,
  Input,
  Stack,
  Text,
  type StackProps,
} from "@mantine/core";
import { useDebouncedCallback } from "@mantine/hooks";
import { useState, type FC } from "react";
import { TbSearch, TbSortAscending, TbSortDescending } from "react-icons/tb";

export type SortingOrder = "descending" | "ascending";

export type ActionBarData = { query: string; sortingOrder: SortingOrder };

interface ActionBarProps {
  onChange: (data: ActionBarData) => void;
  initialValue: ActionBarData;
  stackProps?: StackProps;
}

const ActionBar: FC<ActionBarProps> = ({
  initialValue,
  onChange,
  stackProps,
}) => {
  const [value, setValue] = useState(initialValue);
  const pushChange = useDebouncedCallback(onChange, 300);

  return (
    <Stack gap={3} {...stackProps}>
      <Group justify="space-between">
        <Input
          rightSection={<TbSearch />}
          value={value.query}
          onChange={(evt) => {
            const newQuery = evt.currentTarget.value;
            setValue((old) => ({ ...old, query: newQuery }));
            pushChange({ ...value, query: newQuery });
          }}
          type="text"
          placeholder="Search..."
          miw="70%"
        />

        <Button
          variant="light"
          size="md"
          onClick={() => {
            const newSortingOrder =
              value.sortingOrder === "descending" ? "ascending" : "descending";
            setValue((old) => ({ ...old, sortingOrder: newSortingOrder }));

            pushChange({ ...value, sortingOrder: newSortingOrder });
          }}
          rightSection={
            value.sortingOrder === "ascending" ? (
              <TbSortAscending size="21" />
            ) : (
              <TbSortDescending size="21" />
            )
          }
        >
          <Text tt="capitalize" style={{ fontVariantNumeric: "tabular-nums" }}>
            {value.sortingOrder}
          </Text>
        </Button>
      </Group>
    </Stack>
  );
};

export default ActionBar;
