import * as core from "@mantine/core";

declare module "@mantine/core" {
    export { core };
    export interface MantineThemeOther {
        lgIconSize: number;
        mdIconSize: number;
    }
}
