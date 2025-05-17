import { Route } from "react-router";
import ErrorBoundary from "../components/ErrorBoundary";
import TournamentDetail from "./TournamentDetail";
import { TournamentList } from "./TournamentList";

const TournamentRoutes = () => (
  <Route path="tournaments">
    <Route
      index
      element={
        <ErrorBoundary>
          <TournamentList />
        </ErrorBoundary>
      }
    />

    <Route
      path=":id"
      element={
        <ErrorBoundary>
          <TournamentDetail />
        </ErrorBoundary>
      }
    />
  </Route>
);

export default TournamentRoutes;
