import { Context } from 'ponder:registry';
import { Tournament } from 'ponder:schema';
import { encodeAbiParameters, Hex, keccak256, toHex } from 'viem';

export const generateMatchID = (r1: Hex, r2: Hex) => {
    const abiEncodedRoots = encodeAbiParameters(
        [{ type: 'bytes32' }, { type: 'bytes32' }],
        [r1, r2],
    );

    return keccak256(abiEncodedRoots);
};

export const shouldSkipTournamentEvent = async (
    address: Hex,
    context: Context,
    level: bigint,
) => {
    const tournament = await context.db.find(Tournament, {
        id: address,
    });

    return !tournament || tournament.level !== level;
};

/**
 * Get a list of strings, concatenate, parse into a Hex value and apply the keccak256 function.
 */
export const generateId = (values: string[]): Hex => {
    return keccak256(toHex(values.join('')));
};

/**
 * Replacer to be used with JSON.stringify as the default internal
 * parser does not deal with bigint yet.
 * @param key
 * @param value
 * @returns
 */
const replacerForBigInt = (_key: any, value: any) => {
    return typeof value === 'bigint' ? value.toString() : value;
};

export const stringifyContent = (value: Record<string, any>, separator = '') =>
    JSON.stringify(value, replacerForBigInt, separator);
