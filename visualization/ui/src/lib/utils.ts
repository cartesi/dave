const replacerForBigInt = (_key: unknown, value: unknown) => {
  return typeof value === "bigint" ? value.toString() : value;
};

export const stringifyContent = (
  value: Record<string, unknown>,
  separator = ""
) => JSON.stringify(value, replacerForBigInt, separator);

export const timestampToMillis = (timestamp: string) =>
  parseInt(timestamp) * 1000;
