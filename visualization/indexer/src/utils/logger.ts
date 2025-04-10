import * as winston from 'winston';

const logFormat = winston.format.printf(
    ({ level, message, label, timestamp, ...meta }) => {
        return `${timestamp} ${level} [${label}${meta?.eventName ?? ''}]: ${message}`;
    },
);

const createLogger = (
    messageLabel: string,
    serviceName: string,
    logLevel = 'info',
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
        defaultMeta: { service: serviceName },
        transports: [new winston.transports.Console()],
    });
};

export default createLogger;
