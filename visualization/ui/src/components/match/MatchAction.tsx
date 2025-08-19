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
import BisectionGraph from "./BisectionGraph";

interface MatchActionProps {
    isInitial?: boolean;
    claim?: Claim;
    tournamentCycleRange: CycleRange;
    bisectionCycleRange: CycleRange;
}

const MatchAction: FC<MatchActionProps> = ({
    bisectionCycleRange,
    isInitial = false,
    tournamentCycleRange,
    claim,
}) => {
    const theme = useMantineTheme();
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const wrapClaimGroup = isSmallDevice ? "wrap" : "nowrap";

    return (
        <Card>
            <Grid align="center" columns={12}>
                <GridCol span={{ base: 12, sm: 5 }}>
                    <Group
                        justify={isInitial ? "flex-end" : "space-between"}
                        wrap={wrapClaimGroup}
                    >
                        {claim && <ClaimCard claim={claim} />}
                        <Text ff="monospace" fw="bold" tt="uppercase">
                            {isInitial ? "Initial" : "Bisection"}
                        </Text>
                    </Group>
                </GridCol>
                <GridCol span={{ base: 12, sm: 7 }}>
                    <BisectionGraph
                        cycleLimits={tournamentCycleRange}
                        bisection={bisectionCycleRange}
                    />
                </GridCol>
            </Grid>
        </Card>
    );
};

export default MatchAction;
