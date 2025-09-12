import {
    Anchor,
    Breadcrumbs,
    Button,
    Card,
    Group,
    Menu,
    MenuDropdown,
    MenuItem,
    MenuTarget,
    Text,
    type BreadcrumbsProps,
} from "@mantine/core";
import { slice } from "ramda";
import type { FC, ReactNode } from "react";
import { Link } from "react-router";
import { useIsSmallDevice } from "../../hooks/useIsSmallDevice";

export type HierarchyConfig = {
    title: ReactNode;
    href: string;
};

type HierarchyProps = {
    separator?: string;
    hierarchyConfig: HierarchyConfig[];
    breadcrumbOpts?: BreadcrumbsProps;
};

type ShortFormatProps = {
    configs: HierarchyConfig[];
    visibleQuantity?: number;
    separator?: string;
};

const ShortFormat: FC<ShortFormatProps> = ({
    configs,
    visibleQuantity = 2,
    separator = "/",
}) => {
    visibleQuantity = visibleQuantity < 2 ? 2 : visibleQuantity;
    const configSize = configs.length;
    const configsAsMenu = slice(0, -visibleQuantity, configs);
    const fullDisplayConfigs = slice(
        configSize - visibleQuantity,
        configSize,
        configs,
    );

    const lastFullDisplayConfigItem = fullDisplayConfigs.length - 1;

    return (
        <Breadcrumbs separator={separator}>
            <Menu width={200} shadow="md">
                <MenuTarget>
                    <Button variant="light" size="compact-sm">
                        ...
                    </Button>
                </MenuTarget>

                <MenuDropdown>
                    {configsAsMenu.map((config, index) => (
                        <MenuItem key={`menu-item-${index}`}>
                            <Group justify="center">
                                <Anchor component={Link} to={config.href}>
                                    {config.title}
                                </Anchor>
                            </Group>
                        </MenuItem>
                    ))}
                </MenuDropdown>
            </Menu>
            {fullDisplayConfigs.map((c, index) => {
                if (lastFullDisplayConfigItem === index)
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

const FullForm: FC<HierarchyProps> = ({
    hierarchyConfig,
    breadcrumbOpts,
    separator,
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

export const Hierarchy: FC<HierarchyProps> = ({
    hierarchyConfig,
    separator = "/",
    breadcrumbOpts,
}) => {
    const { isSmallDevice } = useIsSmallDevice();

    const showShortForm = isSmallDevice && hierarchyConfig.length > 4;

    return (
        <Card
            bg="var(--mantine-color-body)"
            px={0}
            py="sm"
            m={0}
            shadow="0"
            withBorder={false}
            pos="sticky"
            top="calc(var(--app-shell-header-height) - 3px)"
            style={{
                zIndex: 10,
            }}
        >
            {showShortForm ? (
                <ShortFormat
                    configs={hierarchyConfig}
                    separator={separator}
                    visibleQuantity={3}
                />
            ) : (
                <FullForm
                    hierarchyConfig={hierarchyConfig}
                    separator={separator}
                    breadcrumbOpts={breadcrumbOpts}
                />
            )}
        </Card>
    );
};
