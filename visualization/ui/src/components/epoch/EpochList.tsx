import { Stack } from "@mantine/core";
import type { FC } from "react";
import type { Epoch } from "../types";
import { EpochCard } from "./EpochCard";

type Props = { epochs: Epoch[] };

export const EpochList: FC<Props> = (props) => {
    // sort epoch by index in descending order
    const epochs = props.epochs.sort((a, b) => b.index - a.index);

    return (
        <Stack gap={5}>
            {epochs.map((epoch) => (
                <EpochCard key={epoch.index} epoch={epoch} />
            ))}
        </Stack>
    );
};
