import { Card, Grid, GridCol, Group, Text } from "@mantine/core";
import { type FC } from "react";
import type { CycleRange } from "../types";
import CycleRangeGraph from "./CycleRangeGraph";

export interface MatchLimitRangeCardProps {
    cycleRange: CycleRange;
    text?: string;
}

const MatchLimitRangeCard: FC<MatchLimitRangeCardProps> = ({
    cycleRange,
    text = "Initial",
}) => {
    return (
        <Card>
            <Grid align="center" columns={12}>
                <GridCol span={{ base: 12, sm: 5 }}>
                    <Group justify="flex-end">
                        <Text ff="monospace" fw="bold" tt="uppercase">
                            {text}
                        </Text>
                    </Group>
                </GridCol>
                <GridCol span={{ base: 12, sm: 7 }}>
                    <CycleRangeGraph
                        cycleLimits={cycleRange}
                        cycleRange={cycleRange}
                    />
                </GridCol>
            </Grid>
        </Card>
    );
};

export default MatchLimitRangeCard;
