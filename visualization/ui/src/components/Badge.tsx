import type { ComponentProps, FC } from "react";

const Badge: FC<ComponentProps<"div">> = ({ className, children, ...rest }) => {
  return (
    <div
      className={`badge badge-sm mt-1.5 ${className ? className : ""}`}
      {...rest}
    >
      {children}
    </div>
  );
};

export default Badge;
