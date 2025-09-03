import {
    Anchor,
    Breadcrumbs,
    Text,
    type BreadcrumbsProps,
} from "@mantine/core";
import type { FC } from "react";
import { Link } from "react-router";

export type HierarchyConfig = {
    title: string;
    href: string;
};

type HierarchyProps = {
    separator?: string;
    hierarchyConfig: HierarchyConfig[];
    breadcrumbOpts?: BreadcrumbsProps;
};

export const Hierarchy: FC<HierarchyProps> = ({
    hierarchyConfig,
    separator = "/",
    breadcrumbOpts,
}) => {
    const lastConfigIndex = hierarchyConfig.length - 1;

    return (
        <Breadcrumbs separator={separator} {...breadcrumbOpts}>
            {hierarchyConfig.map((c, index) => {
                if (lastConfigIndex === index)
                    return <Text c="dimmed"> {c.title}</Text>;

                return (
                    <Anchor key={index} to={c.href} component={Link}>
                        {c.title}
                    </Anchor>
                );
            })}
        </Breadcrumbs>
    );
};
