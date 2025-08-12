import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import { Route, Routes } from "react-router";
import theme from "./providers/theme";
import Home from "./view/home/Home";

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
