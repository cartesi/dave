import { Grid, GridCol, Group, Text, useMantineTheme } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import { type FC } from "react";
import { ClaimText } from "../../tournament/ClaimText";
import type { Claim, CycleRange } from "../../types";
import CycleRangeGraph from "../CycleRangeGraph";

type AdvanceActionCardProps = {
    claim: Claim;
    range: CycleRange;
    rangeLimit: CycleRange;
    text?: string;
};

export const AdvanceActionCard: FC<AdvanceActionCardProps> = ({
    claim,
    range,
    rangeLimit,
    text = "Bisection",
}) => {
    const theme = useMantineTheme();
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const wrapClaimGroup = isSmallDevice ? "wrap" : "nowrap";

    return (
        <Grid align="center" columns={12}>
            <GridCol span={{ base: 12, sm: 5 }}>
                <Group justify="space-between" wrap={wrapClaimGroup}>
                    <ClaimText claim={claim} />
                    <Text ff="monospace" fw="bold" tt="uppercase">
                        {text}
                    </Text>
                </Group>
            </GridCol>
            <GridCol span={{ base: 12, sm: 7 }}>
                <CycleRangeGraph cycleLimits={rangeLimit} cycleRange={range} />
            </GridCol>
        </Grid>
    );
};
