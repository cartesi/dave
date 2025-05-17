import type { FC, PropsWithChildren } from "react";
import { useLocation } from "react-router";
import Breadcrumbs from "./Breadcrumbs";

const View: FC<PropsWithChildren> = ({ children }) => {
  const location = useLocation();
  const pathnames = location.pathname.split("/").filter((path) => path !== "");
  const links = pathnames.map((pathname) => ({
    path: `/${pathname}`,
    name: pathname,
  }));

  return (
    <section className="bg-base-200 h-screen grid grid-rows-[auto_1fr]">
      <header className="sticky bg-white z-10 top-0 shadow-sm rounded-t-lg sm:px-3">
        <div className="flex flex-col justify-center h-full py-3 px-1 sm:px-3">
          <Breadcrumbs links={[{ name: "Home", path: "/" }, ...links]} />
        </div>
      </header>
      <div className="px-5 pt-3 overflow-y-auto">{children}</div>
    </section>
  );
};

export default View;
