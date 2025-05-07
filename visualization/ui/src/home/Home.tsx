import type { FC } from "react";
import { Link } from "react-router";

const fakeStats = [
  {
    title: "Tournaments",
    value: "10",
    description: "Last 7 days",
    action: () => (
      <Link to="/tournaments" className="link link-info text-xs">
        View
      </Link>
    ),
  },
  {
    title: "Players",
    classes: "text-info",
    value: 20,
    description: "↗︎ 10 (50%)",
  },
  {
    title: "Matches",
    classes: "text-info",
    value: 90,
    description: `↗︎ 20 (2%)`,
  },
];

const Home: FC = () => {
  return (
    <section className="flex flex-col justify-center items-center h-full">
      <div className="stats shadow sm:w-1/2 w-full">
        {fakeStats.map((stat) => (
          <div className="stat place-items-center">
            <div className="stat-title">{stat.title}</div>
            <div className={`stat-value ${stat.classes ?? ""}`}>
              {stat.value}
            </div>
            <div className={`stat-desc ${stat.classes ?? ""}`}>
              {stat.description} {stat.action && stat.action()}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
};

export default Home;
