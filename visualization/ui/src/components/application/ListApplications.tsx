import { Stack } from "@mantine/core";
import type { FC } from "react";
import type { Application } from "../types";
import { ApplicationCard } from "./Application";

type Props = { applications: Application[] };

const ListApplications: FC<Props> = ({ applications }) => {
    return (
        <Stack gap={5}>
            {applications.map((app) => (
                <ApplicationCard key={app.address} application={app} />
            ))}
        </Stack>
    );
};

export default ListApplications;
