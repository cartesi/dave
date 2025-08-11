import {
  AppShell,
  AppShellHeader,
  AppShellMain,
  Container,
  Group,
  useMantineTheme,
} from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import type { FC, PropsWithChildren } from "react";
import { Link } from "react-router";
import CartesiLogo from "../icons/CartesiLogo";

const Layout: FC<PropsWithChildren> = ({ children }) => {
  const theme = useMantineTheme();
  const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);

  return (
    <AppShell>
      <AppShellHeader>
        <Group h="100%" justify="space-between" align="center" px="lg">
          <Link to="/" aria-label="Home">
            <CartesiLogo height={isSmallDevice ? 30 : 40} />
          </Link>
        </Group>
      </AppShellHeader>
      <AppShellMain>
        <Container px={isSmallDevice ? "0" : ""}>{children}</Container>
      </AppShellMain>
    </AppShell>
  );
};

export default Layout;
