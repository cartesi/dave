import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import { Route, Routes } from "react-router";
import Home from "./home/Home";
import theme from "./providers/theme";

function App() {
    return (
        <MantineProvider theme={theme} defaultColorScheme="auto">
            <Routes>
                <Route path="/" element={<Home />} />
            </Routes>
        </MantineProvider>
    );
}

export default App;
