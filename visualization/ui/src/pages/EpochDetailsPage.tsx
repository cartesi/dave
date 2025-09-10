import {
    Anchor,
    Badge,
    Group,
    Stack,
    Text,
    Title,
    useMantineTheme,
} from "@mantine/core";
import type { FC } from "react";
import { TbClockFilled, TbInbox, TbTrophy } from "react-icons/tb";
import { Link, useParams } from "react-router";
import { CycleRangeFormatted } from "../components/CycleRangeFormatted";
import { useEpochStatusColor } from "../components/epoch/useEpochStatusColor";
import { InputList } from "../components/input/InputList";
import PageTitle from "../components/layout/PageTitle";
import type { Epoch, Input, Tournament } from "../components/types";
import { routePathBuilder } from "../routes/routePathBuilder";

type Props = {
    tournament?: Tournament | null;
    epoch: Epoch;
    inputs: Input[];
};

export const EpochDetailsPage: FC<Props> = ({ tournament, epoch, inputs }) => {
    const theme = useMantineTheme();
    const epochStatusColor = useEpochStatusColor(epoch);
    const params = useParams();
    const tournamentUrl = routePathBuilder.topTournament(params);
    const tournamentColor = epoch.inDispute ? epochStatusColor : "";

    return (
        <Stack>
            <PageTitle Icon={TbClockFilled} title="Epoch" />
            <Group>
                <Text>Status</Text>
                <Badge color={epochStatusColor}>{epoch.status}</Badge>
                {epoch.inDispute && (
                    <Badge variant="outline" color={epochStatusColor}>
                        disputed
                    </Badge>
                )}
            </Group>

            {tournament && (
                <Anchor
                    component={Link}
                    to={tournamentUrl}
                    variant="text"
                    c={tournamentColor}
                >
                    <Group gap="xs">
                        <Group gap="sm">
                            <TbTrophy
                                size={theme.other.mdIconSize}
                                color={tournamentColor}
                            />
                            <Text c={tournamentColor}>Tournament</Text>
                        </Group>
                        <CycleRangeFormatted
                            size="md"
                            range={[tournament.startCycle, tournament.endCycle]}
                        />
                    </Group>
                </Anchor>
            )}

            <Group gap="xs">
                <TbInbox size={theme.other.mdIconSize} />
                <Title order={3}>Inputs</Title>
            </Group>
            <InputList inputs={inputs} />
        </Stack>
    );
};
