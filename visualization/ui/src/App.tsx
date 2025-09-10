import { MantineProvider, Stack, Text, Title } from "@mantine/core";
import "@mantine/core/styles.css";
import { useColorScheme } from "@mantine/hooks";
import { Link, Outlet, Route, Routes, useLocation } from "react-router";
import Layout from "./components/layout/Layout";
import { Redirect } from "./components/navigation/Redirect";
import { EpochDetailsContainer } from "./containers/EpochDetailsContainer";
import { EpochsContainer } from "./containers/EpochsContainer";
import { HomeContainer } from "./containers/Home";
import { TournamentContainer } from "./containers/TournamentContainer";
import DataProvider from "./providers/DataProvider";
import theme from "./providers/theme";
import { routePathBuilder } from "./routes/routePathBuilder";

const LayoutWithOutlet = () => (
    <Layout>
        <Outlet />
    </Layout>
);

const NotFound = () => {
    const location = useLocation();

    return (
        <Stack align="center" py="lg">
            <Title order={1}>Oops</Title>
            <Title order={2}>Can't find the following path</Title>
            <Text c="orange">{location.pathname}</Text>
            <Link to={routePathBuilder.apps()}>
                Check the applications page
            </Link>
        </Stack>
    );
};

function App() {
    const colorScheme = useColorScheme();
    return (
        <DataProvider>
            <MantineProvider
                theme={theme}
                forceColorScheme={colorScheme ?? "light"}
            >
                <Routes>
                    <Route element={<LayoutWithOutlet />}>
                        <Route
                            path={routePathBuilder.base}
                            element={<Redirect to={routePathBuilder.apps()} />}
                        />

                        <Route
                            path={routePathBuilder.apps()}
                            element={<HomeContainer />}
                        />

                        <Route
                            path={routePathBuilder.appDetail()}
                            element={<Redirect to={routePathBuilder.apps()} />}
                        />

                        <Route
                            path={routePathBuilder.appEpochs()}
                            element={<EpochsContainer />}
                        />

                        <Route
                            path={routePathBuilder.appEpochDetails()}
                            element={<EpochDetailsContainer />}
                        />

                        <Route
                            path={routePathBuilder.topTournament()}
                            element={<TournamentContainer />}
                        />

                        <Route path="*" element={<NotFound />} />
                    </Route>
                </Routes>
            </MantineProvider>
        </DataProvider>
    );
}

export default App;
