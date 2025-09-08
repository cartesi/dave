import { Group, Stack, Text } from "@mantine/core";
import { type FC } from "react";
import { TbClockFilled } from "react-icons/tb";
import type { Hex } from "viem";
import { EpochList } from "../components/epoch/EpochList";
import PageTitle from "../components/layout/PageTitle";
import { NotFound } from "../components/navigation/NotFound";
import type { Epoch } from "../components/types";

type Props = {
    epochs: Epoch[];
    appId: string | Hex;
};

const NoEpochs: FC<{ appId: string | Hex }> = ({ appId }) => (
    <NotFound>
        <Group gap={2}>
            <Text c="dimmed">No Epochs found for application</Text>
            <Text c="cyan" fw="bold">
                {appId}
            </Text>
        </Group>
    </NotFound>
);

export const EpochsPage: FC<Props> = ({ epochs, appId }) => {
    return (
        <Stack>
            <PageTitle Icon={TbClockFilled} title={`Epochs`} />
            {epochs?.length > 0 ? (
                <EpochList epochs={epochs} />
            ) : (
                <NoEpochs appId={appId} />
            )}
        </Stack>
    );
};
