import {
    useMantineColorScheme,
    type MantineColor,
    type MantinePrimaryShade,
} from "@mantine/core";
import theme from "../providers/theme";

const getCorrectShade = (scheme: "dark" | "light"): number => {
    const shade = theme.primaryShade as MantinePrimaryShade;
    return scheme === "dark" ? shade.dark : shade.light;
};

/**
 * Return correct color with adjusted shade based on color-scheme i.e. dark | light mode.
 * If
 *
 * @param colour {AvailableColor}
 * @returns
 */
const useRightColorShade = (color: MantineColor) => {
    const { colorScheme } = useMantineColorScheme();
    const scheme =
        colorScheme === "auto" || colorScheme === "light" ? "light" : "dark";
    const shadeIndex = getCorrectShade(scheme);

    return theme.colors?.[color]?.[shadeIndex] ?? theme.colors.gray[shadeIndex];
};

export default useRightColorShade;
