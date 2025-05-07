import { Route, Routes } from "react-router";
import { Layout } from "./components/Layout";
import { Redirect } from "./components/Redirect";
import Home from "./home/Home";
import { TournamentList } from "./tournament/TournamentList";

function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route path="/" element={<Home />} />
        <Route path="/tournaments" element={<TournamentList />} />

        {/* Catch-all route */}
        <Route path="*" element={<Redirect to="/" />} />
      </Route>
    </Routes>
  );
}

export default App;
