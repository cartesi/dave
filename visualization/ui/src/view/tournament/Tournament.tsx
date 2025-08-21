import { Stack } from "@mantine/core";
import type { FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { Hierarchy } from "../../components/Hierarchy";
import PageTitle from "../../components/layout/PageTitle";
import { TournamentView } from "../../components/tournament/Tournament";
import type {
    Application,
    Epoch,
    Match,
    Tournament,
} from "../../components/types";

export interface TournamentPageProps {
    /**
     * The application to display.
     */
    application: Application;

    /**
     * The epoch to display.
     */
    epoch: Epoch;

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
    const { application, epoch, onClickMatch, tournament } = props;
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
                ]}
            />
            <Stack>
                <PageTitle Icon={TbTrophyFilled} title="Tournament" />
                <TournamentView
                    tournament={tournament}
                    onClickMatch={onClickMatch}
                />
            </Stack>
        </Stack>
    );
};
