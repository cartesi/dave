import type { Hex } from "viem";
import { applications } from "../stories/data";

export const findApplication = (id: string | Hex) => {
    return applications.find((app) => {
        return (
            app.address.toLowerCase() === id.toLowerCase() ||
            app.name.toLowerCase() === id.toLowerCase()
        );
    });
};
