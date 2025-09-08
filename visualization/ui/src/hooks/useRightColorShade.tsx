import {
    useMantineColorScheme,
    useMantineTheme,
    type MantineColor,
    type MantinePrimaryShade,
    type MantineTheme,
} from "@mantine/core";

const getCorrectShade = (
    scheme: "dark" | "light",
    theme: MantineTheme,
): number => {
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
    const theme = useMantineTheme();
    const { colorScheme } = useMantineColorScheme();
    const scheme =
        colorScheme === "auto" || colorScheme === "light" ? "light" : "dark";
    const shadeIndex = getCorrectShade(scheme, theme);

    return theme.colors?.[color]?.[shadeIndex] ?? theme.colors.gray[shadeIndex];
};

export default useRightColorShade;
