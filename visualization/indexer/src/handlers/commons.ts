import { Context } from 'ponder:registry';
import { Logger } from 'winston';

export interface HandlerParams<T> {
    meta: T;
    context: Context;
    logger: Logger;
}
