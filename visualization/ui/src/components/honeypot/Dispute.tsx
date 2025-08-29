import { Alert, Badge, Breadcrumbs, Group, Stack, Text } from "@mantine/core";
import { IconAlertCircleFilled } from "@tabler/icons-react";
import type { FC } from "react";
import type { Hash } from "viem";

export interface DisputeProps {
    /**
     * Claims that are in the dispute
     */
    claims: Hash[];

    /**
     * Claims that have been eliminated so far
     */
    eliminatedClaims: Hash[];
}

export const Dispute: FC<DisputeProps> = (props) => {
    const { claims, eliminatedClaims } = props;
    return (
        <Alert
            variant="light"
            color="yellow"
            title="Under attack!"
            p={16}
            icon={<IconAlertCircleFilled />}
            radius="md"
        >
            <Stack>
                <Text>
                    Someone is trying to break the honeypot! Rest assured PRT
                    will protect it!
                </Text>
                {claims.length > 0 && (
                    <Group gap="xs">
                        <Breadcrumbs separator="vs" separatorMargin={5}>
                            {claims.map((claim) => (
                                <Badge
                                    variant="default"
                                    ff="monospace"
                                    style={{ textTransform: "none" }}
                                >
                                    {claim.slice(0, 6)}...{claim.slice(-4)}
                                </Badge>
                            ))}
                        </Breadcrumbs>
                    </Group>
                )}
                {eliminatedClaims.length > 0 && (
                    <Group gap="xs">
                        {eliminatedClaims.map((claim) => (
                            <Badge
                                variant="default"
                                ff="monospace"
                                c="dimmed"
                                style={{
                                    textTransform: "none",
                                    textDecoration: "line-through",
                                }}
                            >
                                {claim.slice(0, 6)}...{claim.slice(-4)}
                            </Badge>
                        ))}
                    </Group>
                )}
            </Stack>
        </Alert>
    );
};
