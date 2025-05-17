import { format } from "date-fns";
import { type FC } from "react";
import { TbTournament } from "react-icons/tb";
import { NavLink, resolvePath, useLocation } from "react-router";
import Badge from "../components/Badge";
import Center from "../components/Center";
import { useTournamentList } from "./queries";
import { TournamentStatus } from "./types";

interface SummaryProps {
  value: string;
  title: string;
}

const Summary: FC<SummaryProps> = ({ title, value }) => {
  return (
    <div className="flex flex-col gap-3">
      <div className="place-items-center ">
        <p className="text-md font-bold">{title}</p>
        <div className="font-semibold text-info">{value}</div>
      </div>
    </div>
  );
};

const tournamentLevel = 0;

export const TournamentList: FC = () => {
  const { pathname } = useLocation();

  const { data, isError, isPending, error } = useTournamentList({
    where: { level: tournamentLevel },
  });

  if (isPending)
    return (
      <Center>
        <p className="text-info">Loading tournaments...</p>
      </Center>
    );

  if (isError && error)
    return (
      <Center className="text-error">
        <p>Error fetching tournaments!</p>
        <p>Reason: {error.message}</p>
      </Center>
    );

  if (!data) {
    <Center>
      <p className="text-lg text-info font-bold">No tournaments found...</p>
    </Center>;
  }

  const tournaments = data.tournaments;

  return (
    <ul className="list bg-base-100 rounded-box shadow-md">
      <li className="p-4 pb-2 text-xs opacity-60 tracking-wide">
        Latest tournaments
      </li>

      {tournaments.map((tournament) => (
        <li className="list-row hover:bg-base-200" key={tournament.id}>
          <TbTournament className="size-8 text-info self-center" />

          <div className="flex flex-col">
            <NavLink to={resolvePath(tournament.id, pathname)}>
              <p className="link link-hover hover:link-info ">
                {tournament.id}
              </p>
            </NavLink>

            <p className="text-xs uppercase font-semibold opacity-60">
              {format(tournament.timestamp, "dd/MM/yyyy HH:mm:ss")}
            </p>

            <Badge
              className={
                tournament.status === TournamentStatus.created
                  ? "bg-gray-400 text-white"
                  : tournament.status === TournamentStatus.Started
                  ? "bg-green-400"
                  : "bg-orange-400"
              }
            >
              <span className="capitalize">
                {tournament.status.toLowerCase()}
              </span>
            </Badge>
          </div>

          <div className="flex flex-row gap-3">
            <Summary
              title="Matches"
              value={tournament.totalMatches.toString()}
            />
            <Summary
              title="Commitments"
              value={tournament.totalCommitments.toString()}
            />
          </div>
        </li>
      ))}
    </ul>
  );
};
