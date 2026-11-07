export type Theme = "light" | "dark";

export type Arch = "universal" | "arm64" | "x86_64";

export type IconName =
  | "apple"
  | "download"
  | "arrow-right"
  | "chevron-down"
  | "check"
  | "sun"
  | "moon"
  | "shield"
  | "refresh"
  | "wifi"
  | "plug"
  | "sparkles"
  | "lock"
  | "phone"
  | "folder"
  | "sliders"
  | "user"
  | "activity"
  | "key"
  | "bolt"
  | "arrow-up"
  | "external"
  | "copy"
  | "terminal"
  | "box"
  | "info"
  | "warning"
  | "close"
  | "menu"
  | "plus"
  | "code";

export interface DownloadOption {
  arch: Arch;
  title: string;
  detail: string;
  icon: IconName;
  href: string;
  recommended?: boolean;
}
