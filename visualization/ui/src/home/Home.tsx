import { useQuery } from "@tanstack/react-query";
import request from "graphql-request";
import type { FC } from "react";
import Stat from "../components/Stat";
import { graphql } from "../generated/graphql";
import { graphqlUrl } from "../lib/config";
import type { UnfoldDocumentNodeQuery } from "../lib/types";

const SummaryQuery = graphql(`
  query Summary {
    tournaments(limit: 1) {
      totalCount
    }

    matches: matchs(limit: 1) {
      totalCount
    }

    matchStarted: matchs(limit: 1, where: { status: STARTED }) {
      totalCount
    }

    matchFinished: matchs(limit: 1, where: { status: FINISHED }) {
      totalCount
    }

    commitments: commitments(limit: 1) {
      totalCount
    }

    commitmentInDispute: commitments(limit: 1, where: { status: PLAYING }) {
      totalCount
    }

    commitmentWaiting: commitments(limit: 1, where: { status: WAITING }) {
      totalCount
    }
  }
`);

type SummaryQueryReturn = UnfoldDocumentNodeQuery<typeof SummaryQuery>;

const prepareStats = (data?: SummaryQueryReturn) => {
  return {
    tournaments: [
      {
        title: "Total",
        value: data?.tournaments.totalCount ?? 0,
      },
    ],
    matches: [
      { title: "Total", value: data?.matches.totalCount ?? 0 },
      {
        title: "In Progress",
        value: data?.matchStarted.totalCount ?? 0,
      },
      {
        title: "Finalized",
        value: data?.matchFinished.totalCount ?? 0,
      },
    ],
    commitments: [
      { title: "Total", value: data?.commitments.totalCount ?? 0 },
      {
        title: "In Dispute",
        value: data?.commitmentInDispute.totalCount ?? 0,
      },
      {
        title: "Waiting",
        value: data?.commitmentWaiting.totalCount ?? 0,
      },
    ],
  };
};

const Home: FC = () => {
  const { data } = useQuery({
    queryKey: ["home", "summary"],
    queryFn: () => request(graphqlUrl, SummaryQuery),
  });

  const stats = prepareStats(data);

  const entries = Object.entries(stats);

  return (
    <section className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 pt-8">
      {entries.map(([title, stats]) => (
        <section
          key={title}
          className="p-3 grid grid-flow-row-dense gap-4 rounded-lg shadow-lg ring-1 ring-black/5"
        >
          <h1 className="text-xl font-semibold capitalize">{title}</h1>
          <div className="stats shadow px-3 w-full">
            {stats.map((stat, index) => (
              <Stat key={`tournament-${index}`} stat={stat} />
            ))}
          </div>
        </section>
      ))}
    </section>
  );
};

export default Home;
