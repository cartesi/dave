import { Group, Stack, Text, useMantineTheme } from "@mantine/core";
import { fromUnixTime } from "date-fns";
import { type FC } from "react";
import { TbLeafOff } from "react-icons/tb";
import useRightColorShade from "../../../hooks/useRightColorShade";
import { ClaimText } from "../../tournament/ClaimText";
import type { Claim } from "../../types";
import { dateFormatter } from "./utils";

type LeafMatchSealedActionCardProps = {
    timestamp: number;
    claim: Claim;
};

export const LeaftMatchSealedActionCard: FC<LeafMatchSealedActionCardProps> = ({
    timestamp,
    claim,
}) => {
    const theme = useMantineTheme();
    const baseColor = useRightColorShade("cyan");
    const text = "Match Sealed";

    return (
        <Stack>
            <Group justify="space-between">
                <ClaimText claim={claim} />
                <Text ff="monospace" fw="bold" tt="uppercase" c="dimmed">
                    {text}
                </Text>
            </Group>
            <Group justify="flex-end" gap={3}>
                <TbLeafOff size={theme.other.mdIconSize} color={baseColor} />
                <Text c={baseColor} size="sm">
                    {dateFormatter.format(fromUnixTime(timestamp))}
                </Text>
            </Group>
        </Stack>
    );
};
