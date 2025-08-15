import { MantineProvider, Stack, Text, Title } from "@mantine/core";
import "@mantine/core/styles.css";
import {
    Link,
    Outlet,
    Route,
    Routes,
    useHref,
    useLocation,
    useParams,
} from "react-router";
import Layout from "./components/layout/Layout";
import theme from "./providers/theme";

const Root = () => {
    return (
        <>
            <h1>Home</h1>
            <Link to="/apps/1">The App 1</Link>
        </>
    );
};
const AppDetails = () => {
    const { appId } = useParams();
    const href = useHref(`epochs/2`);
    console.log(href);

    return (
        <>
            <h1>Apps</h1>
            <Link to={`/apps/${appId}/epochs/2`}>Epoch 2</Link>
        </>
    );
};

const EpochDetails = () => {
    const { epochId, appId } = useParams();
    const href = useHref(`tt/12345677-22333444555`);
    console.log(href);

    return (
        <>
            <h1>Epoch {epochId}</h1>
            <Link
                to={`/apps/${appId}/epochs/${epochId}/tt/12345677-22333444555`}
            >
                Top Tournament 1
            </Link>
        </>
    );
};

const TopTournamentDetail = () => {
    const { epochId, appId, ttId } = useParams();
    const href = useHref(`match/10`);
    console.log(href);

    return (
        <>
            <h1>Top Tournament {ttId?.replace("-", " ")}</h1>
            <Link
                to={`/apps/${appId}/epochs/${epochId}/tt/12345677-22333444555/matches/10`}
            >
                Match 10
            </Link>
        </>
    );
};

const MidTournamentDetail = () => {
    const { mtId } = useParams();
    const href = useHref(`matches/2`);
    console.log(href);

    return (
        <>
            <h1>Mid Tournament {mtId?.replace("-", " ")}</h1>
            <Link to={href}>Mid Match 2</Link>
        </>
    );
};

const MatchDetails = () => {
    const { matchId } = useParams();
    const href = useHref("mt/4444444-5555555");

    return (
        <>
            <h1>Match {matchId}</h1>
            <Link to={href}>Mid tournament</Link>
        </>
    );
};

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
            <Link to={"/"}>Back to Home</Link>
        </Stack>
    );
};

function App() {
    return (
        <MantineProvider theme={theme} defaultColorScheme="auto">
            <Routes>
                <Route element={<LayoutWithOutlet />}>
                    {/* <Route path="/" element={<Home />} /> */}
                    <Route path="/" element={<Root />} />

                    <Route path="apps/:appId">
                        <Route index element={<AppDetails />} />
                        <Route path="epochs/:epochId">
                            <Route index element={<EpochDetails />} />
                            <Route path="tt/:ttId">
                                <Route
                                    index
                                    element={<TopTournamentDetail />}
                                />
                                <Route path="matches/:matchId">
                                    <Route index element={<MatchDetails />} />
                                    <Route path="mt/:mtId">
                                        <Route
                                            index
                                            element={<MidTournamentDetail />}
                                        />
                                    </Route>
                                </Route>
                            </Route>
                        </Route>
                    </Route>
                    {/* <Route path="apps/:appId" element={<AppDetails />} /> */}
                    {/* <Route
                        path="apps/:appId/epochs/:epochId"
                        element={<EpochDetails />}
                    /> */}

                    {/* <Route
                        path="apps/:appId/epochs/:epochId/tt/:ttId"
                        element={<TopTournamentDetail />}
                    /> */}

                    {/* <Route
                        path="apps/:appId/epochs/:epochId/tt/:ttId/matches/:matchId"
                        element={<MatchDetails />}
                    /> */}

                    {/* <Route
                        path="apps/:appId/epochs/:epochId/tt/:ttId/matches/:matchId/mt/:mtId"
                        element={<MidTournamentDetail />}
                    /> */}
                    <Route path="*" element={<NotFound />} />
                </Route>
            </Routes>
        </MantineProvider>
    );
}

export default App;
