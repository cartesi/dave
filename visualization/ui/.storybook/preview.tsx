import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import type { Preview, StoryContext, StoryFn } from "@storybook/react-vite";
import theme from "../src/providers/theme";

const withMantine = (StoryFn: StoryFn, context: StoryContext) => {
  const currentBg = context.globals.backgrounds?.value ?? "light";
  return (
    <>
      <MantineProvider forceColorScheme={currentBg} theme={theme}>
        {StoryFn(context.args, context)}
      </MantineProvider>
    </>
  );
};

const preview: Preview = {
  initialGlobals: {
    backgrounds: { value: "light" },
  },
  parameters: {
    backgrounds: {
      options: {
        light: { name: "light", value: "#ffffffff" },
        dark: { name: "dark", value: "#333" },
      },
    },
    controls: {
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },
  },
  decorators: [withMantine],
};

export default preview;
