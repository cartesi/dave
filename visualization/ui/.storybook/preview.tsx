import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import type { Preview, StoryContext, StoryFn } from "@storybook/react-vite";
import React from "react";
import { MemoryRouter } from "react-router";
import Layout from "../src/components/layout/Layout";
import theme from "../src/providers/theme";

const withRouter = (StoryFn: StoryFn, context: StoryContext) => (
    <MemoryRouter>{StoryFn(context.args, context)}</MemoryRouter>
);

const withLayout = (StoryFn: StoryFn, context: StoryContext) => {
    const { title } = context;
    const [sectionType] = title.split("/");

    if (sectionType.toLowerCase().includes("pages"))
        return <Layout>{StoryFn(context.args, context)}</Layout>;

    return <>{StoryFn(context.args, context)}</>;
};
const withMantine = (StoryFn: StoryFn, context: StoryContext) => {
    const currentBg = context.globals.backgrounds?.value ?? "light";

    return (
        <MantineProvider forceColorScheme={currentBg} theme={theme}>
            {StoryFn(context.args, context)}
        </MantineProvider>
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
    decorators: [
        // Order matters. So layout decorator first. Fn calling is router(mantine(layout))
        withLayout,
        withMantine,
        withRouter,
    ],
};

export default preview;
