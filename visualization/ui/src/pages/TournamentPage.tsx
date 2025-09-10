import { Stack } from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import PageTitle from "../components/layout/PageTitle";
import { TournamentView } from "../components/tournament/TournamentView";
import type { Match, Tournament } from "../components/types";

export interface TournamentPageProps {
    /**
     * Callback for when a match is clicked. Useful for navigating to the match page.
     */
    onClickMatch?: (match: Match) => void;

    /**
     * Tournament to display.
     */
    tournament: Tournament;
}

export const TournamentPage: FC<TournamentPageProps> = (props) => {
    const { onClickMatch, tournament } = props;
    return (
        <Stack>
            <PageTitle Icon={TbTrophyFilled} title="Tournament" />
            <TournamentView
                tournament={tournament}
                onClickMatch={onClickMatch}
            />
        </Stack>
    );
};
