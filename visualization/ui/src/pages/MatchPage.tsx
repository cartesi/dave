import { Stack } from "@mantine/core";
import type { FC } from "react";
import { TbSwords } from "react-icons/tb";
import PageTitle from "../components/layout/PageTitle";
import { MatchView } from "../components/match/MatchView";
import type { CycleRange, Match, Tournament } from "../components/types";

export interface MatchPageProps {
    /**
     * The tournament to display.
     */
    tournament: Tournament;

    /**
     * The match to display.
     */
    match: Match;

    /**
     * The current timestamp.
     */
    now: number;
}

export const MatchPage: FC<MatchPageProps> = (props) => {
    const { tournament, match, now } = props;
    const range = [tournament.startCycle, tournament.endCycle] as CycleRange;

    return (
        <Stack>
            <PageTitle Icon={TbSwords} title="Match" />
            <MatchView
                height={tournament.height}
                range={range}
                match={match}
                now={now}
            />
        </Stack>
    );
};
