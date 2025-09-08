import { Center, Title, type CenterProps } from "@mantine/core";
import type { FC } from "react";

export const NotFound: FC<CenterProps> = ({ children, ...rest }) => {
    return (
        <Center mah="40%" h="300" {...rest}>
            {children ? (
                children
            ) : (
                <Title order={2} c="dimmed">
                    Not Found
                </Title>
            )}
        </Center>
    );
};
