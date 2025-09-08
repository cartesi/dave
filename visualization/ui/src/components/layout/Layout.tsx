import {
    AppShell,
    AppShellHeader,
    AppShellMain,
    Container,
    Group,
    useMantineTheme,
} from "@mantine/core";
import { useMediaQuery, useViewportSize } from "@mantine/hooks";
import type { FC, PropsWithChildren } from "react";
import { Link } from "react-router";
import CartesiLogo from "../icons/CartesiLogo";

const Layout: FC<PropsWithChildren> = ({ children }) => {
    const theme = useMantineTheme();
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const { height } = useViewportSize();

    return (
        <AppShell>
            <AppShellHeader>
                <Group
                    h="100%"
                    justify="space-between"
                    align="center"
                    px={isSmallDevice ? "xs" : "lg"}
                >
                    <Link to="/" aria-label="Home">
                        <CartesiLogo height={isSmallDevice ? 30 : 40} />
                    </Link>
                </Group>
            </AppShellHeader>
            <AppShellMain>
                <Container
                    px={isSmallDevice ? "sm" : ""}
                    mih={`calc(${height}px - var(--app-shell-header-height))`}
                    strategy="grid"
                >
                    {children}
                </Container>
            </AppShellMain>
        </AppShell>
    );
};

export default Layout;
