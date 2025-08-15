import { Stack } from "@mantine/core";
import type { FC } from "react";
import { InputCard } from "./Input";
import type { Input } from "./types";

interface Props {
    inputs: Input[];
}

export const InputList: FC<Props> = ({ inputs }) => {
    return (
        <Stack gap="xs">
            {inputs.map((input) => (
                <InputCard input={input} key={input.index} />
            ))}
        </Stack>
    );
};
