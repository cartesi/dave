import {
    Badge,
    Box,
    Button,
    Card,
    Collapse,
    Group,
    SegmentedControl,
    Stack,
    Text,
    type MantineColor,
} from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";
import { type FC } from "react";
import { TbEyeMinus, TbEyePlus } from "react-icons/tb";
import useRightColorShade from "../../hooks/useRightColorShade";
import theme from "../../providers/theme";
import { LongText } from "../LongText";
import type { Input, InputStatus } from "./types";

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
                    <Text fw="bold">Sender</Text>
                    <Badge color={statusColor}>{input.status}</Badge>
                </Group>
                <LongText
                    value={input.sender}
                    shorten={false}
                    style={{ lineBreak: "anywhere" }}
                    size="sm"
                    c="dimmed"
                />
            </Stack>
            <Group py="sm" justify="flex-start" gap="5">
                <Badge variant="outline">Index: {input.index}</Badge>
                <Badge variant="outline">
                    <Group gap={2}>
                        Output Hash:
                        <LongText
                            value={input.outputHash}
                            shorten={true}
                            size="xs"
                        />
                    </Group>
                </Badge>
            </Group>

            <Box my="sm">
                <Button
                    variant="light"
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
                    {displayMeta ? "Show less" : "Show more"}
                </Button>
            </Box>

            <Collapse
                in={displayMeta}
                p="xs"
                style={{
                    boxShadow: "0px 0px 3px inset",
                    borderRadius: "0.5rem",
                }}
            >
                <Stack gap="xs">
                    <Group>
                        <Text fw="bold">Payload</Text>
                        <SegmentedControl
                            data={[
                                { label: "Raw", value: "raw" },
                                {
                                    label: "ABI Decoded",
                                    value: "abi",
                                    disabled: true,
                                },
                            ]}
                        />
                    </Group>
                    <LongText
                        value={input.payload}
                        shorten={false}
                        size="xs"
                        style={{ lineBreak: "anywhere" }}
                    />
                </Stack>
            </Collapse>
        </Card>
    );
};
