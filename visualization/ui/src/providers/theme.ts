import { createTheme, DEFAULT_THEME, mergeMantineTheme } from "@mantine/core";

const theme = createTheme({
  fontFamily: "serif",
  primaryColor: "cyan",
});

export default mergeMantineTheme(DEFAULT_THEME, theme);
