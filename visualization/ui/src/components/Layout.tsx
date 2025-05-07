import type { FC } from "react";
import { NavLink, Outlet } from "react-router";

const navlinks = [
  {
    name: "Home",
    path: "/",
  },
  {
    name: "Tournaments",
    path: "/tournaments",
  },
];

export const Layout: FC = () => {
  return (
    <div className="grid grid-cols-1  gap-2 md:grid-cols-6 p-3 h-full w-full">
      <nav className="hidden md:block md:col-span-1">
        <ul className="menu menu-lg bg-base-200 rounded-box w-auto">
          {navlinks.map((link) => (
            <li key={link.name}>
              <NavLink
                to={link.path}
                className={({ isActive }) => {
                  const classes = isActive
                    ? "bg-linear-to-r from-cyan-500 to-blue-500"
                    : "";

                  return `${classes} justify-center`;
                }}
              >
                {link.name}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
      <main className="shadow-lg md:col-span-5 ">
        <Outlet />
      </main>
    </div>
  );
};
