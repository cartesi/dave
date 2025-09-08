import { Badge, Group, Stack, Text, Title } from "@mantine/core";
import type { FC } from "react";
import { TbClockFilled, TbInbox } from "react-icons/tb";
import { useEpochStatusColor } from "../components/epoch/useEpochStatusColor";
import { InputList } from "../components/input/InputList";
import PageTitle from "../components/layout/PageTitle";
import { Hierarchy } from "../components/navigation/Hierarchy";
import type { Application, Epoch, Input } from "../components/types";
import theme from "../providers/theme";

type Props = {
    application: Application;
    epoch: Epoch;
    inputs: Input[];
};

export const EpochDetailsPage: FC<Props> = ({ application, epoch, inputs }) => {
    const epochStatusColor = useEpochStatusColor(epoch);

    return (
        <Stack gap="lg">
            <Hierarchy
                hierarchyConfig={[
                    { title: "Home", href: "/" },
                    { title: application.name, href: `/${application.name}` },
                    { title: `Epoch ${epoch.index}`, href: "#" },
                ]}
            />
            <Stack>
                <PageTitle Icon={TbClockFilled} title="Epoch" />
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
