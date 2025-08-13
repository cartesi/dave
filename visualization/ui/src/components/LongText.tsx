import {
    ActionIcon,
    CopyButton,
    Group,
    Text,
    type TextProps,
    Tooltip,
    rem,
} from "@mantine/core";
import { IconCheck, IconCopy } from "@tabler/icons-react";
import type { FC } from "react";

export interface LongTextProps extends TextProps {
    value: string;
    shorten?: boolean | number;
    copyButton?: boolean;
}

export const LongText: FC<LongTextProps> = (props) => {
    const { value, copyButton = true, ...textProps } = props;

    // if the shorten prop is a boolean and true, we use 4
    // if the shorten prop is a number, we divide it by 2, and separate by ...
    const sliceSize =
        typeof props.shorten === "boolean"
            ? props.shorten
                ? 4
                : 0
            : typeof props.shorten === "number"
              ? props.shorten / 2
              : 4;

    // if the value starts with 0x, we need to pad the slice size by 2
    const pad = value.startsWith("0x") ? 2 : 0;

    // boolean to decide if we should shorten the text
    const shorten =
        typeof props.shorten === "boolean" ? props.shorten : sliceSize > 0;

    const text = shorten
        ? value
              .slice(0, sliceSize + pad)
              .concat("...")
              .concat(value.slice(-sliceSize))
        : value;
    const size = textProps.size;
    return (
        <Group gap={2} wrap="nowrap">
            <Text {...textProps}>{text}</Text>
            {copyButton && (
                <CopyButton value={value} timeout={2000}>
                    {({ copied, copy }) => (
                        <Tooltip
                            label={copied ? "Copied" : "Copy"}
                            withArrow
                            position="right"
                        >
                            <ActionIcon
                                color={copied ? "teal" : "gray"}
                                variant="subtle"
                                size={size}
                                onClick={copy}
                            >
                                {copied ? (
                                    <IconCheck
                                        style={{
                                            width: rem(size === "xs" ? 12 : 16),
                                        }}
                                    />
                                ) : (
                                    <IconCopy
                                        style={{
                                            width: rem(size === "xs" ? 12 : 16),
                                        }}
                                    />
                                )}
                            </ActionIcon>
                        </Tooltip>
                    )}
                </CopyButton>
            )}
        </Group>
    );
};
