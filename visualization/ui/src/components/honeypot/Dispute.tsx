import {
    Alert,
    Badge,
    Breadcrumbs,
    Group,
    Stack,
    Text,
    useMantineTheme,
} from "@mantine/core";
import { IconAlertCircleFilled } from "@tabler/icons-react";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
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

    /**
     * The winner of the dispute
     */
    winner?: Hash;
}

type Claim = {
    hash: Hash;
    eliminated: boolean;
    winner: boolean;
};

export const Dispute: FC<DisputeProps> = (props) => {
    const { claims, eliminatedClaims, winner } = props;
    const all: Claim[] = [];
    if (winner) {
        all.push({ hash: winner, eliminated: false, winner: true });
    }
    all.push(
        ...claims.map((hash) => ({ hash, winner: false, eliminated: false })),
    );
    all.push(
        ...eliminatedClaims.map((hash) => ({
            hash,
            winner: false,
            eliminated: true,
        })),
    );

    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

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
                {all.length > 0 && (
                    <Group gap="xs">
                        <Breadcrumbs separator="vs" separatorMargin={5}>
                            {all.map((claim) => (
                                <Badge
                                    variant="default"
                                    ff="monospace"
                                    c={claim.eliminated ? "dimmed" : undefined}
                                    style={{
                                        textTransform: "none",
                                        textDecoration: claim.eliminated
                                            ? "line-through"
                                            : undefined,
                                    }}
                                    leftSection={
                                        claim.winner && (
                                            <TbTrophyFilled
                                                size={16}
                                                color={gold}
                                            />
                                        )
                                    }
                                >
                                    {claim.hash.slice(0, 6)}...
                                    {claim.hash.slice(-4)}
                                </Badge>
                            ))}
                        </Breadcrumbs>
                    </Group>
                )}
            </Stack>
        </Alert>
    );
};
