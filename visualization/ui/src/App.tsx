import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import { Route, Routes } from "react-router";
import Home from "./home/Home";

function App() {
  return (
    <MantineProvider>
      <Routes>
        <Route path="/" element={<Home />} />
      </Routes>
    </MantineProvider>
  );
}

export default App;
