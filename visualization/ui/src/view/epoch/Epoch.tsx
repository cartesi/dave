import { Badge, Group, Stack, Text, Title } from "@mantine/core";
import type { FC } from "react";
import { TbClockFilled, TbInbox } from "react-icons/tb";
import { useEpochStatusColor } from "../../components/epoch/useEpochStatusColor";
import { Hierarchy, type HierarchyConfig } from "../../components/Hierarchy";
import { InputList } from "../../components/input/InputList";
import type { Input } from "../../components/input/types";
import PageTitle from "../../components/layout/PageTitle";
import type { Epoch } from "../../components/types";
import theme from "../../providers/theme";

type Props = {
    epoch: Epoch;
    hierarchyConfig: HierarchyConfig[];
    inputs: Input[];
};

const EpochView: FC<Props> = ({ epoch, hierarchyConfig, inputs }) => {
    const epochStatusColor = useEpochStatusColor(epoch);

    return (
        <Stack gap="lg">
            <Hierarchy hierarchyConfig={hierarchyConfig} />
            <Stack>
                <PageTitle Icon={TbClockFilled} title={`Epoch Detail`} />
                <Group>
                    <Text>Status</Text>
                    <Badge color={epochStatusColor}>{epoch.status}</Badge>
                </Group>

                <Group gap="xs">
                    <TbInbox size={theme.other.mdIconSize} />
                    <Title order={3}>Inputs</Title>
                </Group>
                <InputList inputs={inputs} />
            </Stack>
        </Stack>
    );
};

export default EpochView;
