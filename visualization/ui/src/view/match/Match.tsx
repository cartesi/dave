import { Stack } from "@mantine/core";
import type { FC } from "react";
import { TbSwords } from "react-icons/tb";
import { Hierarchy } from "../../components/Hierarchy";
import PageTitle from "../../components/layout/PageTitle";
import { MatchView } from "../../components/match/Match";
import type {
    Application,
    CycleRange,
    Epoch,
    Match,
    Tournament,
} from "../../components/types";

export interface MatchPageProps {
    application: Application;
    epoch: Epoch;
    tournament: Tournament;
    match: Match;
    parentMatches: Pick<Match, "claim1" | "claim2">[];
}

export const MatchPage: FC<MatchPageProps> = (props) => {
    const { application, epoch, tournament, match, parentMatches } = props;
    const range = [tournament.startCycle, tournament.endCycle] as CycleRange;

    return (
        <Stack gap="lg">
            <Hierarchy
                hierarchyConfig={[
                    { title: "Home", href: "/" },
                    {
                        title: application.name,
                        href: `/${application.name}`,
                    },
                    {
                        title: `epoch ${epoch.index}`,
                        href: `/${application.name}/epochs/${epoch.index}`,
                    },
                    {
                        title: `tournament ${tournament.startCycle} - ${tournament.endCycle}`,
                        href: `/${application.name}/epochs/${epoch.index}/tournaments/${tournament.startCycle}`,
                    },
                ]}
            />
            <Stack>
                <PageTitle Icon={TbSwords} title="Match" />
                <MatchView
                    height={tournament.height}
                    parentMatches={parentMatches}
                    range={range}
                    match={match}
                />
            </Stack>
        </Stack>
    );
};
