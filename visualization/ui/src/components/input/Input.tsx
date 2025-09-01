import {
    Badge,
    Button,
    Card,
    Collapse,
    Group,
    Stack,
    Text,
    Textarea,
    type MantineColor,
} from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";
import { type FC } from "react";
import { TbEyeMinus, TbEyePlus } from "react-icons/tb";
import useRightColorShade from "../../hooks/useRightColorShade";
import theme from "../../providers/theme";
import { LongText } from "../LongText";
import type { Input, InputStatus } from "../types";

interface Props {
    input: Input;
}

const getStatusColor = (status: InputStatus): MantineColor => {
    switch (status) {
        case "NONE":
            return "gray";
        case "ACCEPTED":
            return "green";
        default:
            return "red";
    }
};

// TODO: Define what else will be inside like payload (decoding etc)
export const InputCard: FC<Props> = ({ input }) => {
    const [displayMeta, { toggle: toggleDisplayMeta }] = useDisclosure(false);
    const statusColor = useRightColorShade(getStatusColor(input.status));

    return (
        <Card shadow="md" withBorder>
            <Stack gap={3}>
                <Group justify="space-between">
                    <Text fw="bold"># {input.index}</Text>
                    {input.status !== "ACCEPTED" && (
                        <Badge color={statusColor}>{input.status}</Badge>
                    )}
                </Group>
                <LongText
                    value={input.sender}
                    shorten={false}
                    size="sm"
                    c="dimmed"
                />
                <Group>
                    <Button
                        variant="transparent"
                        size="compact-xs"
                        onClick={toggleDisplayMeta}
                        leftSection={
                            displayMeta ? (
                                <TbEyeMinus size={theme.other.mdIconSize} />
                            ) : (
                                <TbEyePlus size={theme.other.mdIconSize} />
                            )
                        }
                    >
                        Payload
                    </Button>
                </Group>
                <Collapse in={displayMeta}>
                    <Textarea readOnly value={input.payload} />
                </Collapse>
            </Stack>
        </Card>
    );
};
