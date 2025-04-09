import * as winston from 'winston';

const logFormat = winston.format.printf(
    ({ level, message, label, timestamp, ...meta }) => {
        return `${timestamp} ${level} [${label}${meta?.eventName ?? ''}]: ${message}`;
    },
);
type defaultMeta = { [k in string]: string };

const createLogger = (
    messageLabel: string,
    serviceName: string,
    logLevel = 'info',
    defaultMetas: defaultMeta = {},
) => {
    return winston.createLogger({
        level: logLevel,
        format: winston.format.combine(
            winston.format((info) => {
                info.level = info.level.toLocaleUpperCase();
                return info;
            })(),
            winston.format.label({ label: messageLabel }),
            winston.format.timestamp(),
            winston.format.colorize({ all: true }),
            logFormat,
        ),
        defaultMeta: { service: serviceName, ...defaultMetas },
        transports: [new winston.transports.Console()],
    });
};

export const generateEventLoggers = <T extends string>(
    eventNames: readonly T[],
    parentLogger: winston.Logger,
) => {
    const loggers = {} as Record<T, winston.Logger>;
    eventNames.forEach((name) => {
        loggers[name] = parentLogger.child({
            eventName: `:${name}`,
        });
    });

    return loggers;
};

export default createLogger;
