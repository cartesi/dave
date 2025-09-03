import { Stack } from "@mantine/core";
import { type FC } from "react";
import { TbClockFilled } from "react-icons/tb";
import { EpochList } from "../components/epoch/EpochList";
import PageTitle from "../components/layout/PageTitle";
import { Hierarchy } from "../components/navigation/Hierarchy";
import type { Application, Epoch } from "../components/types";

type Props = {
    application: Application;
    epochs: Epoch[];
};

export const ApplicationPage: FC<Props> = ({ application, epochs }) => {
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
                <EpochList epochs={epochs} />
            </Stack>
        </Stack>
    );
};
