import {
    AppShell,
    Card,
    createTheme,
    DEFAULT_THEME,
    mergeMantineTheme,
    Modal,
    virtualColor,
    type DefaultMantineColor,
    type MantineColorsTuple,
} from "@mantine/core";

type ExtendedCustomColors =
    | "open"
    | "disputed"
    | "closed"
    | "finalized"
    | DefaultMantineColor;

declare module "@mantine/core" {
    export interface MantineThemeColorsOverride {
        colors: Record<ExtendedCustomColors, MantineColorsTuple>;
    }
}

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
            dark: "dark",
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
