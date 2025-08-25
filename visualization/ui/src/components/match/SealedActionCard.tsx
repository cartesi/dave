import {
    Anchor,
    Badge,
    Group,
    Stack,
    Text,
    useMantineTheme,
} from "@mantine/core";
import { type FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { href, Link } from "react-router";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import { ClaimText } from "../tournament/ClaimText";
import type { Claim, CycleRange, Tournament } from "../types";

type SealedActionCardProps = {
    claim: Claim;
    tournament: Tournament;
};

export const SealedActionCard: FC<SealedActionCardProps> = ({
    claim,
    tournament,
}) => {
    const text = "Match Sealed";
    // refactor: demonstration purpose it probably needs to be the tournament address instead of Mcycles.
    const middleTournamentPath = href(
        `mt/${tournament.startCycle}-${tournament.endCycle}`,
    );

    const theme = useMantineTheme();
    const cycleRange: CycleRange = [tournament.startCycle, tournament.endCycle];

    return (
        <Stack>
            <Group justify="space-between">
                <ClaimText claim={claim} />
                <Text ff="monospace" fw="bold" tt="uppercase" c="dimmed">
                    {text}
                </Text>
            </Group>
            <Group justify="flex-start">
                <Badge color="green">
                    New {tournament.level} Tournament Created
                </Badge>
            </Group>
            <Anchor to={{ pathname: middleTournamentPath }} component={Link}>
                <Group gap="xs" wrap="nowrap" align="center">
                    <TbTrophyFilled size={theme.other.mdIconSize} />
                    <Text tt="capitalize">Tournament</Text>
                    <CycleRangeFormatted cycleRange={cycleRange} />
                </Group>
            </Anchor>
        </Stack>
    );
};
