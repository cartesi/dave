import { Stack } from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import PageTitle from "../components/layout/PageTitle";
import { TournamentView } from "../components/tournament/TournamentView";
import type { Tournament } from "../components/types";

export interface TournamentPageProps {
    /**
     * Tournament to display.
     */
    tournament: Tournament;
}

export const TournamentPage: FC<TournamentPageProps> = (props) => {
    const { tournament } = props;
    return (
        <Stack>
            <PageTitle Icon={TbTrophyFilled} title="Tournament" />
            <TournamentView tournament={tournament} />
        </Stack>
    );
};
