import type { FC } from "react";
import { NavLink } from "react-router";

interface Props {
  links: { name: string; path: string }[];
  classNames?: string;
}

const Breadcrumbs: FC<Props> = ({ links, classNames }) => {
  const last = links.length - 1;
  return (
    <div className={`breadcrumbs text-sm ${classNames ?? ""}`}>
      <ul>
        {links.map((link, index) => (
          <li key={index}>
            {index !== last ? (
              <NavLink to={link.path} className="capitalize">
                {link.name}
              </NavLink>
            ) : (
              <span className="capitalize no-underline">{link.name}</span>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
};

export default Breadcrumbs;
