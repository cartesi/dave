import type { TypedDocumentNode } from "@graphql-typed-document-node/core";
import type { ReactNode } from "react";

/**
 * Helper to extract the types of a returned graphQL query
 * of type TypedDocumentNode
 *
 */
export type UnfoldDocumentNodeQuery<T> = T extends TypedDocumentNode<
  infer QueryType,
  never
>
  ? QueryType
  : unknown;

export interface RouteConfig {
  path: string;
  component: ReactNode;
}
