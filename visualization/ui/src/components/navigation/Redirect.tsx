import { useEffect, type FC } from "react";
import { useNavigate } from "react-router";
import { routePathBuilder } from "../../routes/routePathBuilder";

type BuilderPaths = Omit<typeof routePathBuilder, "base">;

type AcceptedPaths = ReturnType<BuilderPaths[keyof BuilderPaths]>;
interface Props {
    to: AcceptedPaths;
    opts?: {
        replace: boolean;
    };
}

export const Redirect: FC<Props> = ({ to, opts = { replace: true } }) => {
    const navigate = useNavigate();

    useEffect(() => {
        navigate(to, { replace: opts.replace });
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    return "";
};
