import {
    AppShell,
    Card,
    createTheme,
    DEFAULT_THEME,
    mergeMantineTheme,
    Modal,
    virtualColor,
} from "@mantine/core";

const theme = createTheme({
    colors: {
        open: virtualColor({ name: "open", light: "green", dark: "green" }),
        disputed: virtualColor({
            name: "disputed",
            light: "orange",
            dark: "orange",
        }),
        closed: virtualColor({ name: "closed", light: "cyan", dark: "gray" }),
        finalized: virtualColor({
            name: "finalized",
            light: "dark",
            dark: "gray",
        }),
    },
    primaryColor: "cyan",
    primaryShade: {
        dark: 8,
        light: 6,
    },
    other: {
        lgIconSize: 40,
        mdIconSize: 24,
        zIndexXS: 100,
        zIndexSM: 200,
        zIndexMD: 300,
        zIndexLG: 400,
        zIndexXL: 500,
    },
    components: {
        Modal: Modal.extend({
            defaultProps: {
                size: "lg",
                centered: true,
                overlayProps: {
                    backgroundOpacity: 0.55,
                    blur: 3,
                },
            },
        }),
        AppShell: AppShell.extend({
            defaultProps: {
                header: { height: 60 },
                aside: {
                    width: 0,
                    breakpoint: "sm",
                },
            },
        }),
        Card: Card.extend({
            defaultProps: {
                shadow: "sm",
                withBorder: true,
            },
        }),
    },
});

export default mergeMantineTheme(DEFAULT_THEME, theme);
