import { useEffect, useState, type FC } from "react";
import { useNavigate } from "react-router";
import Countdown from "./Countdown";

const redirectInSeconds = 5 as const;

interface Props {
  to?: string;
}

export const Redirect: FC<Props> = ({ to = "/" }) => {
  const navigate = useNavigate();
  const [counter, setCounter] = useState<number>(redirectInSeconds);

  useEffect(() => {
    const millis = 1000;
    const counterId = setInterval(() => {
      setCounter((prev) => prev - 1);
    }, millis);

    const redirectId = setTimeout(() => {
      navigate(to);
    }, redirectInSeconds * millis);
    return () => {
      clearTimeout(redirectId);
      clearInterval(counterId);
    };
  }, [navigate, to]);

  return (
    <div className="place-content-center grid grid-cols-1 h-full">
      <div className="hero bg-base-200 min-h-screen">
        <div className="hero-content text-center">
          <div className="max-w-md">
            <h1 className="text-5xl font-bold">You're kind of lost</h1>
            <p className="py-6">There is nothing here</p>
            <p className="text-gray-400 font-light">
              You'll be redirected in{" "}
              <span className="text-cyan-400">
                <Countdown counter={counter >= 0 ? counter.toString() : "0"} />{" "}
              </span>
            </p>
          </div>
        </div>
      </div>
    </div>
  );
};
