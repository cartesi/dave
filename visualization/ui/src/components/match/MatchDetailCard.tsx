import {
    Card,
    Grid,
    GridCol,
    Group,
    Text,
    useMantineTheme,
} from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import { type FC } from "react";
import { ClaimCard } from "../tournament/ClaimCard";
import type { Claim, CycleRange } from "../types";
import CycleRangeGraph from "./CycleRangeGraph";

interface Props {
    claim: Claim;
    tournamentCycleRange: CycleRange;
    bisectionCycleRange: CycleRange;
    midText?: string;
}

const MatchDetailCard: FC<Props> = ({
    bisectionCycleRange,
    tournamentCycleRange,
    claim,
    midText = "Bisection",
}) => {
    const theme = useMantineTheme();
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const wrapClaimGroup = isSmallDevice ? "wrap" : "nowrap";

    return (
        <Card>
            <Grid align="center" columns={12}>
                <GridCol span={{ base: 12, sm: 5 }}>
                    <Group justify="space-between" wrap={wrapClaimGroup}>
                        <ClaimCard claim={claim} />
                        <Text ff="monospace" fw="bold" tt="uppercase">
                            {midText}
                        </Text>
                    </Group>
                </GridCol>
                <GridCol span={{ base: 12, sm: 7 }}>
                    <CycleRangeGraph
                        cycleLimits={tournamentCycleRange}
                        cycleRange={bisectionCycleRange}
                    />
                </GridCol>
            </Grid>
        </Card>
    );
};

export default MatchDetailCard;
