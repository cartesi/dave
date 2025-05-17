import type { CodegenConfig } from "@graphql-codegen/cli";
import { join } from "node:path";

const schemaPath = join(".", "graphql", "schema.graphql");

const config: CodegenConfig = {
  schema: schemaPath,
  documents: ["src/**/*.tsx", "!src/graphql/**/*"],
  ignoreNoDocuments: true,
  generates: {
    "./src/generated/graphql/": {
      preset: "client",
      config: {
        // documentMode: "string",
        useTypeImports: true,
        enumsAsConst: true,
      },
      plugins: [],
    },
  },
};

export default config;
