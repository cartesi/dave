import type { FC } from "react";
import { TbHome, TbTournament } from "react-icons/tb";
import { NavLink, Outlet } from "react-router";
import View from "./View";

const navlinks = [
  {
    icon: () => <TbHome className="text-lg" />,
    name: "Home",
    path: "/",
  },
  {
    icon: () => <TbTournament className="text-lg" />,
    name: "Tournaments",
    path: "/tournaments",
  },
];

export const Layout: FC = () => {
  return (
    <div className="grid grid-cols-1  gap-2 md:grid-cols-6 px-3 pt-2 h-full w-full">
      <nav className="hidden md:block md:col-span-1 overflow-hidden">
        <ul className="menu menu-lg bg-base-200 rounded-box w-auto">
          {navlinks.map((link) => (
            <li key={link.name}>
              <NavLink
                to={link.path}
                className={({ isActive }) => {
                  const classes = isActive ? "text-cyan-500" : "";

                  return `${classes} justify-start `;
                }}
              >
                {link.icon()}
                {link.name}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
      <main className="shadow-sm md:col-span-5">
        <View>
          <Outlet />
        </View>
      </main>
    </div>
  );
};
