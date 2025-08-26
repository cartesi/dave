import { Card, type CardProps } from "@mantine/core";
import { type FC } from "react";
import type { Match, MatchAction, Tournament } from "../types";
import { AdvanceActionCard } from "./actions/AdvanceActionCard";
import { EliminatedByTimeoutActionCard } from "./actions/EliminatedByTimeoutCard";
import { LeaftMatchSealedActionCard } from "./actions/LeafMatchSealedCard";
import { SealedActionCard } from "./actions/SealedActionCard";
import { TimeoutActionCard } from "./actions/TimeoutActionCard";

interface Props extends CardProps {
    tournament: Tournament;
    match: Match;
    action: MatchAction;
}

export const MatchActionCard: FC<Props> = (props) => {
    const { action, match, tournament, ...cardProps } = props;
    return (
        <Card withBorder radius="md" {...cardProps}>
            {action.type === "advance" ? (
                <AdvanceActionCard
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    range={action.range}
                    rangeLimit={[tournament.startCycle, tournament.endCycle]}
                />
            ) : action.type === "match_sealed_inner_tournament_created" ? (
                <SealedActionCard
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    tournament={action.tournament}
                />
            ) : action.type === "timeout" ? (
                <TimeoutActionCard
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    timestamp={action.timestamp}
                />
            ) : action.type === "leaf_match_sealed" ? (
                <LeaftMatchSealedActionCard
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    timestamp={action.timestamp}
                />
            ) : action.type === "match_eliminated_by_timeout" ? (
                <EliminatedByTimeoutActionCard
                    claimOne={match.claim1}
                    claimTwo={match.claim2}
                    timestamp={action.timestamp}
                />
            ) : (
                ""
            )}
        </Card>
    );
};
