import { useMantineTheme } from "@mantine/core";
import { useMediaQuery, useViewportSize } from "@mantine/hooks";

export const useIsSmallDevice = () => {
    const theme = useMantineTheme();
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const viewport = useViewportSize();

    return {
        isSmallDevice,
        viewport,
    };
};
