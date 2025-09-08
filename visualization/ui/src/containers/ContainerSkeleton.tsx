import { Card, Group, Skeleton, Stack } from "@mantine/core";

export const ContainerSkeleton = () => {
    const repeat = Array.from({ length: 4 });

    return (
        <Stack mt="md">
            <Group>
                <Skeleton animate={false} height={34} circle mb="xl" />
                <Skeleton animate={false} height={13} width="40%" mb="xl" />
            </Group>
            {repeat.map((_v, index) => (
                <Card key={`app-skeleton-${index}`}>
                    <Stack gap="sm">
                        <Skeleton height={10} width="30%" radius="xl" />
                        <Skeleton height={10} width="50%" radius="xl" />
                    </Stack>
                    <Group justify="space-between" pt="lg">
                        <Skeleton height={8} mt={6} width="10%" radius="xl" />
                        <Skeleton height={8} mt={6} width="10%" radius="xl" />
                    </Group>
                </Card>
            ))}
        </Stack>
    );
};
