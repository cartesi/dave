import { Route, Routes } from "react-router";
import ErrorBoundary from "./components/ErrorBoundary";
import { Layout } from "./components/Layout";
import { Redirect } from "./components/Redirect";
import Home from "./home/Home";
import TournamentRoutes from "./tournament/routes";

function App() {
  return (
    <ErrorBoundary fallback={<p>Hummm...</p>}>
      <Routes>
        <Route element={<Layout />}>
          <Route path="/" element={<Home />} />

          {TournamentRoutes()}

          {/* Catch-all route */}
          <Route path="*" element={<Redirect to="/" />} />
        </Route>
      </Routes>
    </ErrorBoundary>
  );
}

export default App;
