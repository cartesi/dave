import {
    Button,
    Collapse,
    Group,
    Paper,
    Stack,
    Textarea,
    useComputedColorScheme,
    useMantineTheme,
} from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";
import { type FC } from "react";
import { TbFile, TbFileText, TbTrophyFilled } from "react-icons/tb";
import type { Hex } from "viem";
import { ClaimText } from "../ClaimText";
import type { Claim } from "../types";
import { ClaimTimelineItem } from "./ClaimTimelineItem";

export interface WinnerItemProps {
    /**
     * Winner claim
     */
    claim: Claim;

    /**
     * Current timestamp
     */
    now: number;

    /**
     * Proof of the winner
     */
    proof: Hex;

    /**
     * Timestamp
     */
    timestamp: number;
}

export const WinnerItem: FC<WinnerItemProps> = (props) => {
    const { claim, now, proof, timestamp } = props;

    const [opened, { toggle }] = useDisclosure(false);

    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    const scheme = useComputedColorScheme();
    const bg = scheme === "light" ? theme.colors.yellow[0] : undefined;

    return (
        <ClaimTimelineItem claim={claim} now={now} timestamp={timestamp}>
            <Paper withBorder p={16} radius="lg" bg={bg}>
                <Stack gap="xs">
                    <Group gap="xs">
                        <TbTrophyFilled size={24} color={gold} />
                        <ClaimText claim={claim} withIcon={false} />
                        <Button
                            variant="transparent"
                            rightSection={
                                opened ? (
                                    <TbFile size={16} />
                                ) : (
                                    <TbFileText size={16} />
                                )
                            }
                            size="compact-xs"
                            onClick={toggle}
                        >
                            View proof
                        </Button>
                    </Group>
                    <Collapse in={opened}>
                        <Textarea readOnly rows={10} autosize maxRows={10}>
                            {proof}
                        </Textarea>
                    </Collapse>
                </Stack>
            </Paper>
        </ClaimTimelineItem>
    );
};
