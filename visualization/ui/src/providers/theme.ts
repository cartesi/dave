import {
    AppShell,
    Card,
    createTheme,
    DEFAULT_THEME,
    mergeMantineTheme,
    Modal,
} from "@mantine/core";

const theme = createTheme({
    fontFamily: "serif",
    cursorType: "pointer",
    primaryColor: "cyan",
    primaryShade: {
        dark: 8,
        light: 6,
    },
    other: {
        lgIconSize: 40,
        mdIconSize: 24,
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
