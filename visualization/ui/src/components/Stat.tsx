import type { ComponentProps, FC, ReactNode } from "react";

interface Props extends ComponentProps<"section"> {
  stat: {
    title: string | ReactNode;
    value: string | ReactNode;
    description?: string | ReactNode;
  };
}

const Stat: FC<Props> = ({ stat, className, ...rest }) => {
  return (
    <section className={`stat place-items-center ${className ?? ""}`} {...rest}>
      <div className="stat-title">{stat.title}</div>
      <div className={`stat-value`}>{stat.value}</div>
      {stat.description && <div className="stat-desc">{stat.description}</div>}
    </section>
  );
};

export default Stat;
