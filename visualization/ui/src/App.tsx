import { MantineProvider, Stack, Text, Title } from "@mantine/core";
import "@mantine/core/styles.css";
import { useColorScheme } from "@mantine/hooks";
import type { FC } from "react";
import {
    Link,
    Outlet,
    Route,
    Routes,
    useLocation,
    useParams,
} from "react-router";
import Layout from "./components/layout/Layout";
import { Redirect } from "./components/navigation/Redirect";
import type { Tournament } from "./components/types";
import { EpochDetailsContainer } from "./containers/EpochDetailsContainer";
import { EpochsContainer } from "./containers/EpochsContainer";
import { HomeContainer } from "./containers/Home";
import { MatchDetailContainer } from "./containers/MatchDetailContainer";
import { SubMatchDetailContainer } from "./containers/SubMatchDetailContainer";
import { SubTournamentContainer } from "./containers/SubTournamentContainer";
import { TournamentContainer } from "./containers/TournamentContainer";
import DataProvider from "./providers/DataProvider";
import theme from "./providers/theme";
import { routePathBuilder } from "./routes/routePathBuilder";

const LayoutWithOutlet = () => (
    <Layout>
        <Outlet />
    </Layout>
);

const RouteNotFound = () => {
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

type Props = { level: Tournament["level"] };

const RedirectToTournament: FC<Props> = ({ level }) => {
    const params = useParams();
    const tournamentUrl =
        level === "top"
            ? routePathBuilder.topTournament(params)
            : level === "middle"
              ? routePathBuilder.middleTournament(params)
              : routePathBuilder.bottomTournament(params);

    return <Redirect to={tournamentUrl} />;
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

                        <Route
                            path={routePathBuilder.topTournamentMatches()}
                            element={<RedirectToTournament level="top" />}
                        />

                        <Route
                            path={routePathBuilder.matchDetail()}
                            element={<MatchDetailContainer />}
                        />

                        <Route
                            path={routePathBuilder.middleTournament()}
                            element={<SubTournamentContainer level="middle" />}
                        />

                        <Route
                            path={routePathBuilder.middleTournamentMatches()}
                            element={<RedirectToTournament level="middle" />}
                        />

                        <Route
                            path={routePathBuilder.midMatchDetail()}
                            element={<SubMatchDetailContainer level="middle" />}
                        />

                        <Route
                            path={routePathBuilder.bottomTournament()}
                            element={<SubTournamentContainer level="bottom" />}
                        />

                        <Route
                            path={routePathBuilder.bottomTournamentMatches()}
                            element={<RedirectToTournament level="bottom" />}
                        />

                        <Route
                            path={routePathBuilder.btMatchDetail()}
                            element={<SubMatchDetailContainer level="bottom" />}
                        />

                        <Route path="*" element={<RouteNotFound />} />
                    </Route>
                </Routes>
            </MantineProvider>
        </DataProvider>
    );
}

export default App;
