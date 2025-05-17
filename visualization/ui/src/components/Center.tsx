import type { ComponentProps, FC } from "react";

const Center: FC<ComponentProps<"section">> = ({
  children,
  className,
  ...rest
}) => {
  return (
    <section
      className={`grid place-content-center py-5 ${className ? className : ""}`}
      {...rest}
    >
      {children}
    </section>
  );
};

export default Center;
