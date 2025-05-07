import type { CSSProperties, FC } from "react";

interface Props {
  counter: string;
}

const Countdown: FC<Props> = ({ counter }) => {
  const style = { "--value": counter } as CSSProperties;

  return (
    <span className="countdown">
      <span style={style} aria-live="polite" aria-label={counter}>
        {counter}
      </span>
    </span>
  );
};

export default Countdown;
