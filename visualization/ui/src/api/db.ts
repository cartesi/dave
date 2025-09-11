import { omit } from "ramda";
import type { Hex } from "viem";
import type {
    Application,
    Epoch,
    Match,
    Tournament,
} from "../components/types";
import {
    applications,
    type ApplicationEpochs,
    type EpochWithTournament,
} from "../stories/data";

type MatchId = Hex;
type ApplicationId = string | Hex;
type GetTournament = { applicationId: ApplicationId; epochIndex: number };
type GetSubTournament = GetTournament & { matchId: MatchId };
type ListTournamentMatches = {
    tournamentId: Hex;
    applicationId: ApplicationId;
    epochIndex: number;
    matchId?: Hex;
};
type GetMatch = Required<ListTournamentMatches>;

class SyntheticDatabase {
    // Normalizing this data deriving from original stories/data.ts
    // because of its nested naturally that would drive
    // the way we build the function APIs in a odd manner.
    // xxx: Later I'll replace with dexie.js

    // keys may look like this (app_id:epoch_index  |  app_id:epoch_index:match_id)
    // app_id may be the prop name or address (both are valid today in the node json-api)
    private tournaments = new Map<string, Tournament>();
    // keys may look like this (app_id:epoch_index:tournament_id | app_id:epoch_index:match_id:tournament_id)
    // the tournament_id is a hex (here it is a keccak256 derived from the range)
    // but in reality could be the tournament contract address.
    private matches = new Map<string, Match[]>();
    // the key will look like (app_id:epoch_index:tournament_id:match_id)
    // is just to recover the targeted match by id.
    private flatMatches = new Map<string, Match>();
    private applications: Application[] = [];
    private epochs = new Map<string, Epoch[]>();

    constructor() {
        // limit to only mocked honeypot
        console.info(`DB initiating...`);
        const application = applications.find((a) => a.name === "honeypot")!;
        this.applications.push(omit(["epochs"], application));
        this.init(application);
        console.info(`DB initiated.`);
    }

    public getApplication(id: ApplicationId) {
        return (
            this.applications.find(
                (application) =>
                    application.address === id || application.name === id,
            ) ?? null
        );
    }

    public listEpochs(id: ApplicationId) {
        return this.epochs.get(this.generateKey([id])) ?? null;
    }

    public getEpoch(id: ApplicationId, epochIndex: number) {
        if (isNaN(epochIndex)) return null;
        const epochs = this.epochs.get(this.generateKey([id])) ?? [];
        return epochs.find((e) => e.index === epochIndex) ?? null;
    }

    public getTournament({ applicationId, epochIndex }: GetTournament) {
        return (
            this.tournaments.get(
                this.generateKey([applicationId, epochIndex.toString()]),
            ) ?? null
        );
    }

    public getSubTournament({
        applicationId,
        epochIndex,
        matchId,
    }: GetSubTournament) {
        return (
            this.tournaments.get(
                this.generateKey([
                    applicationId,
                    epochIndex.toString(),
                    matchId,
                ]),
            ) ?? null
        );
    }

    public getMatch({
        applicationId,
        epochIndex,
        tournamentId,
        matchId,
    }: GetMatch) {
        const key = this.generateKey([
            applicationId,
            epochIndex.toString(),
            tournamentId,
            matchId,
        ]);

        return this.flatMatches.get(key) ?? null;
    }

    public listTournamentMatches({
        applicationId,
        epochIndex,
        tournamentId,
        matchId,
    }: ListTournamentMatches) {
        const matchKey = matchId ? [matchId] : [];
        const base = this.generateKey([
            applicationId,
            epochIndex.toString(),
            ...matchKey,
        ]);

        return this.matches.get(this.generateKey([base, tournamentId])) ?? null;
    }

    // PRIVATE METHODS

    private init(application: ApplicationEpochs): void {
        for (const epoch of application.epochs) {
            const keyOne = this.generateKey([application.address]);
            const keyTwo = this.generateKey([application.name]);
            const epochs =
                this.epochs.get(keyOne) ?? this.epochs.get(keyTwo) ?? [];
            epochs.push(omit(["tournament"], epoch));
            this.epochs.set(keyOne, epochs);
            this.epochs.set(keyTwo, epochs);

            this.loadData(application, epoch, epoch.tournament);
        }
    }

    private loadData(
        app: ApplicationEpochs,
        epoch: EpochWithTournament,
        tournament?: Tournament,
        match?: Match,
    ): void {
        const matchKey = match ? [match.id] : [];
        const epochIndex = epoch.index.toString();
        const baseOne = this.generateKey([app.address, epochIndex]);
        const baseTwo = this.generateKey([app.name, epochIndex]);
        const keyOne = this.generateKey([baseOne, ...matchKey]);
        const keyTwo = this.generateKey([baseTwo, ...matchKey]);
        if (tournament) {
            // lets empty out the matches.
            const flatTournament: Tournament = { ...tournament, matches: [] };

            // same tournament ref but diff keys composed of app name or address + epoch-index
            this.tournaments.set(keyOne, flatTournament);
            this.tournaments.set(keyTwo, flatTournament);

            for (const match of tournament.matches) {
                const matKeyOne = this.generateKey([keyOne, tournament.id]);
                const matKeyTwo = this.generateKey([keyTwo, tournament.id]);
                const matches =
                    this.matches.get(matKeyOne) ??
                    this.matches.get(matKeyTwo) ??
                    [];
                // no ref to tournament.
                const flatMatch = { ...match, tournament: undefined };
                matches.push(flatMatch);
                this.matches.set(matKeyOne, matches);
                this.matches.set(matKeyTwo, matches);

                const flatKeyOne = this.generateKey([
                    baseOne,
                    tournament.id,
                    match.id,
                ]);
                const flatKeyTwo = this.generateKey([
                    baseTwo,
                    tournament.id,
                    match.id,
                ]);

                this.flatMatches.set(flatKeyOne, flatMatch);
                this.flatMatches.set(flatKeyTwo, flatMatch);

                if (match.tournament)
                    //recursion to traverse the tournaments & matches.
                    this.loadData(app, epoch, match.tournament, match);
            }
        }
    }

    private generateKey(keys: string[]): string {
        return keys.join(":");
    }
}

export const syntheticDbInstance = new SyntheticDatabase();
