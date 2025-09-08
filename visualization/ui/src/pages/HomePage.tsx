import { Stack, Text } from "@mantine/core";
import { type FC } from "react";
import { TbCpu } from "react-icons/tb";
import { ApplicationList } from "../components/application/ApplicationList";
import PageTitle from "../components/layout/PageTitle";
import { NotFound } from "../components/navigation/NotFound";
import type { Application } from "../components/types";

type Props = {
    applications: Application[];
};

const NoApplications = () => (
    <NotFound>
        <Text c="dimmed" size="xl">
            No Applications deployed yet!
        </Text>
    </NotFound>
);

export const HomePage: FC<Props> = (props) => {
    const { applications } = props;

    return (
        <Stack>
            <PageTitle Icon={TbCpu} title="Applications" />
            {applications?.length > 0 ? (
                <ApplicationList applications={applications} />
            ) : (
                <NoApplications />
            )}
        </Stack>
    );
};
