import { Stack } from "@mantine/core";
import type { FC } from "react";
import { useListApplications } from "../api/application.queries";
import {
    Hierarchy,
    type HierarchyConfig,
} from "../components/navigation/Hierarchy";
import { HomePage } from "../pages/HomePage";
import { ContainerSkeleton } from "./ContainerSkeleton";

export const HomeContainer: FC = () => {
    const { data, isLoading } = useListApplications();
    const hierarchyConfig: HierarchyConfig[] = [{ title: "Home", href: "/" }];
    const applications = data?.applications ?? [];

    return (
        <Stack pt="lg" gap="lg">
            <Hierarchy hierarchyConfig={hierarchyConfig} />

            {isLoading ? (
                <ContainerSkeleton />
            ) : (
                <HomePage applications={applications} />
            )}
        </Stack>
    );
};
