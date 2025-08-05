import { Container, Stack } from "@mantine/core";
import type { FC } from "react";
import { ApplicationCard } from "./Application";
import { applications } from "./application.mocks";

const ListApplications: FC = () => {
  return (
    <Container fluid miw="var(--mantine-breakpoint-xs)">
      <Stack gap={5}>
        {applications.map((app) => (
          <ApplicationCard key={app.address} application={app} />
        ))}
      </Stack>
    </Container>
  );
};

export default ListApplications;
