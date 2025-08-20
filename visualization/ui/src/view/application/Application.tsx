import { Stack } from "@mantine/core";
import { type FC } from "react";
import { TbClockFilled } from "react-icons/tb";
import ListEpoch from "../../components/epoch/ListEpoch";
import { Hierarchy } from "../../components/Hierarchy";
import PageTitle from "../../components/layout/PageTitle";
import type { Application, Epoch } from "../../components/types";

type Props = {
    application: Application;
    epochs: Epoch[];
};

const ApplicationView: FC<Props> = ({ application, epochs }) => {
    return (
        <Stack gap="lg">
            <Hierarchy
                hierarchyConfig={[
                    { title: "Home", href: "/" },
                    { title: application.name, href: `/${application.name}` },
                ]}
            />
            <Stack>
                <PageTitle Icon={TbClockFilled} title={`Epochs`} />
                <ListEpoch epochs={epochs} />
            </Stack>
        </Stack>
    );
};

export default ApplicationView;
