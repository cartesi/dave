import { Group, Title } from "@mantine/core";
import type { FC, JSX } from "react";

interface PageTitleProps {
    title: string;
    Icon: JSX.ElementType;
}

const PageTitle: FC<PageTitleProps> = ({ title, Icon }) => {
    return (
        <Group mb="sm" data-testid="page-title">
            <Title order={1} display="inline-flex">
                <Icon
                    size={40}
                    aria-hidden
                    style={{ marginRight: "0.5rem", marginTop: "0.215rem" }}
                />
                {title}
            </Title>
        </Group>
    );
};

export default PageTitle;
