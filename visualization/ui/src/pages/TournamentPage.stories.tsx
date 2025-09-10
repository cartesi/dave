import { Stack } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { Hierarchy } from "../components/navigation/Hierarchy";
import { TournamentBreadcrumbSegment } from "../components/navigation/TournamentBreadcrumbSegment";
import * as TournamentViewStories from "../components/tournament/TournamentView.stories";
import type { Claim, Tournament } from "../components/types";
import { routePathBuilder } from "../routes/routePathBuilder";
import { applications } from "../stories/data";
import { claim, randomMatches } from "../stories/util";
import { TournamentPage } from "./TournamentPage";

const meta = {
    title: "Pages/Tournament",
    component: TournamentPage,
    tags: ["autodocs"],
} satisfies Meta<typeof TournamentPage>;

export default meta;
type Story = StoryObj<typeof meta>;

type Props = Parameters<typeof TournamentPage>[0];

const WithBreadcrumb = (props: Props) => {
    const app = applications[0];
    const params = { appId: app.name, epochIndex: "4" };
    console.log(props.tournament);
    return (
        <Stack gap="lg">
            <Hierarchy
                hierarchyConfig={[
                    { title: "Home", href: "/" },
                    {
                        title: app.name,
                        href: routePathBuilder.appEpochs(params),
                    },
                    {
                        title: `Epoch #4`,
                        href: routePathBuilder.appEpochDetails(params),
                    },
                    {
                        title: <TournamentBreadcrumbSegment level="top" />,
                        href: "#",
                    },
                ]}
            />
            <TournamentPage {...props} />
        </Stack>
    );
};

export const TopLevelClosed: Story = {
    render: WithBreadcrumb,
    args: {
        tournament: TournamentViewStories.NoChallengerYet.args.tournament,
    },
};

export const TopLevelFinalized: Story = {
    render: WithBreadcrumb,
    args: {
        tournament: TournamentViewStories.Finalized.args.tournament,
    },
};

export const TopLevelDispute: Story = {
    render: WithBreadcrumb,
    args: {
        tournament: TournamentViewStories.Ongoing.args.tournament,
    },
};

/**
 * Create random claims
 */
const now = Math.floor(Date.now() / 1000);
const claims: Claim[] = Array.from({ length: 128 }).map((_, i) => claim(i));

const randomTournament: Tournament = {
    startCycle: 1837880065,
    endCycle: 2453987565,
    height: 48,
    level: "top",
    matches: [],
    danglingClaim: undefined,
};
randomMatches(now, randomTournament, claims);

export const TopLevelLargeDispute: Story = {
    render: WithBreadcrumb,
    args: {
        tournament: randomTournament,
    },
};

export const MidLevelDispute: Story = {
    render: WithBreadcrumb,
    args: {
        tournament: TournamentViewStories.MidLevelDispute.args.tournament,
    },
};
