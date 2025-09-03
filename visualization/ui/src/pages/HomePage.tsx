import { Stack, Title } from "@mantine/core";
import { useState, type FC } from "react";
import { TbCpu } from "react-icons/tb";
import ActionBar, { type ActionBarData } from "../components/ActionBar";
import { ApplicationList } from "../components/application/ApplicationList";
import PageTitle from "../components/layout/PageTitle";
import type { Application } from "../components/types";

const initialValue: ActionBarData = { query: "", sortingOrder: "ascending" };

type Props = {
    applications: Application[];
};

export const HomePage: FC<Props> = (props) => {
    const { applications } = props;
    const [search, setSearch] = useState<ActionBarData>(initialValue);
    const resultIsEmpty = applications.length === 0;

    return (
        <Stack>
            <PageTitle Icon={TbCpu} title="Applications" />
            <ActionBar
                initialValue={search}
                onChange={(data) => {
                    setSearch(data);
                }}
            />
            {resultIsEmpty ? (
                <Stack my="lg" align="center">
                    <Title order={2} textWrap="wrap">
                        No results
                    </Title>
                    <Title order={3} textWrap="wrap">
                        It is a case-insensitive search with an exact match on
                        name or address
                    </Title>
                </Stack>
            ) : (
                ""
            )}
            <ApplicationList applications={applications} />
        </Stack>
    );
};
