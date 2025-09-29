import * as core from "@mantine/core";

type ExtendedCustomColors =
    | "open"
    | "disputed"
    | "closed"
    | "finalized"
    | core.DefaultMantineColor;
declare module "@mantine/core" {
    export { core };
    export interface MantineThemeOther {
        lgIconSize: number;
        mdIconSize: number;
        zIndexXS: number;
        zIndexSM: number;
        zIndexMD: number;
        zIndexLG: number;
        zIndexXL: number;
    }

    export interface MantineThemeColorsOverride {
        colors: Record<ExtendedCustomColors, core.MantineColorsTuple>;
    }
}
