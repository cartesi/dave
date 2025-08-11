import { Badge, Card, Group, Stack, Text } from "@mantine/core";
import type { FC } from "react";
import { TbCpu, TbCpuOff, TbInbox } from "react-icons/tb";
import type { Hex } from "viem";
import styles from "./Application.module.css";

type ApplicationState = "ENABLED" | "DISABLED" | "INOPERABLE";
type ConsensusType = "PRT" | "QUORUM" | "AUTHORITY";

export interface Application {
  address: Hex;
  name?: string;
  consensusType: ConsensusType;
  state: ApplicationState;
  processedInputs: number;
}

type Props = { application: Application };

const getStateColour = (state: ApplicationState) => {
  switch (state) {
    case "ENABLED":
      return "green";
    case "DISABLED":
      return "red";
    case "INOPERABLE":
      return "gray";
    default:
      return "black";
  }
};

const iconSize = 24;

export const ApplicationCard: FC<Props> = ({ application }) => {
  const stateColour = getStateColour(application.state);

  return (
    <Card shadow="md" withBorder className={styles.application}>
      <Stack gap="0">
        <Group justify="space-between">
          <Text size="xl">{application.name}</Text>
          <Badge size="md">{application.consensusType}</Badge>
        </Group>
        <Text c="dimmed" size="xs">
          {application.address}
        </Text>
      </Stack>

      <Group pt="md" justify="space-between" align="center">
        <Group gap="3">
          {application.state === "ENABLED" ? (
            <TbCpu color={stateColour} size={iconSize} />
          ) : (
            <TbCpuOff color={stateColour} size={iconSize} />
          )}
          <Badge color={stateColour}>{application.state}</Badge>
        </Group>
        <Group gap="3">
          <TbInbox size={iconSize} />
          <Text>Inputs Processed</Text>
          <Badge variant="dot" size="md">
            {application.processedInputs}
          </Badge>
        </Group>
      </Group>
    </Card>
  );
};
