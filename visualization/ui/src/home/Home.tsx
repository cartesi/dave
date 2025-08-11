import { Stack, Title } from "@mantine/core";
import { useState, type FC } from "react";
import { TbCpu } from "react-icons/tb";
import ActionBar, { type ActionBarData } from "../components/ActionBar";
import ListApplications from "../components/application/ListApplications";
import useApplications from "../components/application/useApplications";
import Layout from "../components/layout/Layout";
import PageTitle from "../components/layout/PageTitle";

const initialValue: ActionBarData = { query: "", sortingOrder: "ascending" };

const Home: FC = () => {
    const [search, setSearch] = useState<ActionBarData>(initialValue);
    const applications = useApplications({
        order: search.sortingOrder,
        application: search.query,
    });

    const resultIsEmpty = applications.length === 0;

    return (
        <Layout>
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
                            It is a case-insensitive search with an exact match
                            on name or address
                        </Title>
                    </Stack>
                ) : (
                    ""
                )}
                <ListApplications applications={applications} />
            </Stack>
        </Layout>
    );
};

export default Home;
