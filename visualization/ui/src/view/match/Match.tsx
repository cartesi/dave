import { Stack } from "@mantine/core";
import type { FC } from "react";
import { TbSwords } from "react-icons/tb";
import { Hierarchy } from "../../components/Hierarchy";
import PageTitle from "../../components/layout/PageTitle";
import { MatchView } from "../../components/match/Match";
import type {
    Application,
    Epoch,
    Match,
    Tournament,
} from "../../components/types";

export interface MatchPageProps {
    application: Application;
    epoch: Epoch;
    tournament: Tournament;
    match: Match;
}

export const MatchPage: FC<MatchPageProps> = (props) => {
    const { application, epoch, tournament, match } = props;
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
                <MatchView tournament={tournament} match={match} />
            </Stack>
        </Stack>
    );
};
