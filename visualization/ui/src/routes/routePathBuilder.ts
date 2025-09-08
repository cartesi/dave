type PathParams = {
    appId?: string;
    epochId?: string;
    ttId?: string;
    mtId?: string;
    btId?: string;
    matchId?: string;
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
        `${routePathBuilder.appEpochs(params)}/${params?.epochId ?? ":epochId"}` as const,
};
