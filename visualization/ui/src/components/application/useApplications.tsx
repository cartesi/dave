import type { SortingOrder } from "../ActionBar";
import type { Application } from "../types";
import { applications } from "./application.mocks";

type Params = { application?: string; order: "ascending" | "descending" };

const collator = new Intl.Collator("en", { sensitivity: "base" });

const buildSortingFn =
    (order: SortingOrder) => (a: Application, b: Application) =>
        order === "ascending"
            ? collator.compare(a.name ?? a.address, b.name ?? b.address)
            : collator.compare(b.name ?? b.address, a.name ?? a.address);

const useApplications = ({ order, application = "" }: Params) => {
    const sortingFn = buildSortingFn(order);
    if (application.trim() === "") return applications.sort(sortingFn);

    return applications
        .filter((app) => {
            const lowercaseApp = application.toLowerCase();
            return (
                app.name?.toLowerCase() === lowercaseApp ||
                app.address.toLowerCase() === lowercaseApp
            );
        })
        .sort(sortingFn);
};

export default useApplications;
