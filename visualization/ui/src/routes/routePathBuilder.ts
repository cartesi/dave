export type RoutePathParams = {
    appId?: string;
    epochIndex?: string;
    matchId?: string;
    midMatchId?: string;
    btMatchId?: string;
};

export const routePathBuilder = {
    base: "/" as const,
    home: () => routePathBuilder.base,
    apps: () => `${routePathBuilder.home()}apps` as const,
    appDetail: (params?: RoutePathParams) =>
        `${routePathBuilder.apps()}/${params?.appId ?? ":appId"}` as const,
    appEpochs: (params?: RoutePathParams) =>
        `${routePathBuilder.appDetail(params)}/epochs` as const,
    appEpochDetails: (params?: RoutePathParams) =>
        `${routePathBuilder.appEpochs(params)}/${params?.epochIndex ?? ":epochIndex"}` as const,
    topTournament: (params?: RoutePathParams) =>
        `${routePathBuilder.appEpochDetails(params)}/tt` as const,
    topTournamentMatches: (params?: RoutePathParams) =>
        `${routePathBuilder.topTournament(params)}/matches` as const,
    matchDetail: (params?: RoutePathParams) =>
        `${routePathBuilder.topTournamentMatches(params)}/${params?.matchId ?? ":matchId"}` as const,
    middleTournament: (params?: RoutePathParams) =>
        `${routePathBuilder.matchDetail(params)}/mt` as const,
    middleTournamentMatches: (params?: RoutePathParams) =>
        `${routePathBuilder.middleTournament(params)}/matches` as const,
    midMatchDetail: (params?: RoutePathParams) =>
        `${routePathBuilder.middleTournamentMatches(params)}/${params?.midMatchId ?? ":midMatchId"}` as const,
    bottomTournament: (params?: RoutePathParams) =>
        `${routePathBuilder.midMatchDetail(params)}/bt` as const,
    bottomTournamentMatches: (params?: RoutePathParams) =>
        `${routePathBuilder.bottomTournament(params)}/matches` as const,
    btMatchDetail: (params?: RoutePathParams) =>
        `${routePathBuilder.bottomTournamentMatches(params)}/${params?.btMatchId ?? ":btMatchId"}` as const,
};
