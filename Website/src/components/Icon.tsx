import type { SVGProps } from "react";
import type { IconName } from "../types";

interface IconProps extends SVGProps<SVGSVGElement> {
  name: IconName;
  className?: string;
}

export function Icon({ name, className = "icon", ...props }: IconProps) {
  return (
    <svg className={className} aria-hidden="true" focusable="false" {...props}>
      <use href={`#i-${name}`} />
    </svg>
  );
}
