import { Card, Group, type CardProps } from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { ClaimText } from "../ClaimText";
import type { Claim } from "../types";

export interface ClaimCardProps extends CardProps {
    /**
     * The claim to display.
     */
    claim: Claim;

    /**
     * The size of the avatar icons.
     */
    iconSize?: number;

    /**
     * Whether to show the parent claims.
     */
    showParents?: boolean;
}

export const ClaimCard: FC<ClaimCardProps> = ({
    claim,
    showParents = true,
    iconSize = 32,
    ...cardProps
}) => {
    return (
        <Card withBorder shadow="sm" radius="lg" {...cardProps}>
            <Group gap="xs" wrap="nowrap">
                <TbTrophyFilled size={24} opacity={0} />
                <ClaimText
                    claim={claim}
                    showParents={showParents}
                    iconSize={iconSize}
                />
            </Group>
        </Card>
    );
};
