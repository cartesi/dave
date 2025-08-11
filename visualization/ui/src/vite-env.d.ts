/// <reference types="vite/client" />

// <reference types="../../indexer/ponder-env.d.ts" />

interface ImportMetaEnv {
    readonly VITE_API_URL: string;
}

interface ImportMeta {
    readonly env: ImportMetaEnv;
}
