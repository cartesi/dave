import { MantineProvider } from "@mantine/core";
import type { FC, PropsWithChildren } from "react";
import theme from "./theme";

export const StyleProvider: FC<PropsWithChildren> = ({ children }) => {
    return <MantineProvider theme={theme}>{children}</MantineProvider>;
};
