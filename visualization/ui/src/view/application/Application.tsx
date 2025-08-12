import { Stack } from "@mantine/core";
import { type FC } from "react";
import { TbClockFilled } from "react-icons/tb";
import ListEpoch from "../../components/epoch/ListEpoch";
import { Hierarchy, type HierarchyConfig } from "../../components/Hierarchy";
import Layout from "../../components/layout/Layout";
import PageTitle from "../../components/layout/PageTitle";
import type { Epoch } from "../../components/types";

type Props = {
    epochs: Epoch[];
    hierarchyConfig: HierarchyConfig[];
};

const ApplicationView: FC<Props> = ({ epochs, hierarchyConfig }) => {
    return (
        <Layout>
            <Stack gap="lg">
                <Hierarchy hierarchyConfig={hierarchyConfig} />
                <Stack>
                    <PageTitle Icon={TbClockFilled} title={`Epochs`} />
                    <ListEpoch epochs={epochs} />
                </Stack>
            </Stack>
        </Layout>
    );
};

export default ApplicationView;
