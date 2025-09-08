type PathParams = {
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
    appDetail: (params?: PathParams) =>
        `${routePathBuilder.apps()}/${params?.appId ?? ":appId"}` as const,
    appEpochs: (params?: PathParams) =>
        `${routePathBuilder.appDetail(params)}/epochs` as const,
    appEpochDetails: (params?: PathParams) =>
        `${routePathBuilder.appEpochs(params)}/${params?.epochIndex ?? ":epochIndex"}` as const,
    topTournament: (params?: PathParams) =>
        `${routePathBuilder.appEpochDetails(params)}/tt` as const,
    matchDetail: (params?: PathParams) =>
        `${routePathBuilder.topTournament(params)}/matches/${params?.matchId ?? ":matchId"}` as const,
    middleTournament: (params?: PathParams) =>
        `${routePathBuilder.matchDetail(params)}/mt` as const,
    midMatchDetail: (params?: PathParams) =>
        `${routePathBuilder.middleTournament(params)}/matches/${params?.midMatchId ?? ":midMatchId"}` as const,
    bottomTournament: (params?: PathParams) =>
        `${routePathBuilder.midMatchDetail(params)}/bt` as const,
    btMatchDetail: (params?: PathParams) =>
        `${routePathBuilder.bottomTournament(params)}/matches/${params?.btMatchId ?? ":btMatchId"}` as const,
};
