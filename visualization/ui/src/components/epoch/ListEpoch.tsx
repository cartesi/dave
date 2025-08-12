import { Stack } from "@mantine/core";
import type { FC } from "react";
import type { Epoch } from "../types";
import { EpochCard } from "./Epoch";

type Props = { epochs: Epoch[] };

const ListEpoch: FC<Props> = ({ epochs }) => {
    return (
        <Stack gap={5}>
            {epochs.map((epoch) => (
                <EpochCard key={epoch.index} epoch={epoch} />
            ))}
        </Stack>
    );
};

export default ListEpoch;
