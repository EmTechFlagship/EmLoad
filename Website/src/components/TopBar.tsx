import { navItems } from "../data/site";
import { useScrolled } from "../hooks/useScrolled";
import type { Theme } from "../types";
import { Icon } from "./Icon";

interface TopBarProps {
  theme: Theme;
  menuOpen: boolean;
  onToggleTheme: () => void;
  onToggleMenu: () => void;
  onCloseMenu: () => void;
  onDownload: () => void;
}

export function TopBar({
  theme,
  menuOpen,
  onToggleTheme,
  onToggleMenu,
  onCloseMenu,
  onDownload,
}: TopBarProps) {
  const scrolled = useScrolled();

  const handleDownload = () => {
    onCloseMenu();
    onDownload();
  };

  return (
    <header className={`topbar${scrolled ? " is-scrolled" : ""}`}>
      <div className="topbar-inner">
        <a className="brand" href="#top" aria-label="EmLoad home">
          <img
            className="brand-mark"
            src="assets/emload-icon.png"
            alt=""
            width={38}
            height={38}
          />
          <span className="brand-name">EmLoad</span>
        </a>

        <nav className="nav" aria-label="Primary">
          {navItems.map((item) => (
            <a key={item.href} href={item.href}>
              {item.label}
            </a>
          ))}
        </nav>

        <div className="topbar-actions">
          <button
            className="icon-button theme-toggle"
            type="button"
            onClick={onToggleTheme}
            aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
          >
            <Icon name="sun" className="icon icon--sun" />
            <Icon name="moon" className="icon icon--moon" />
          </button>
          <button
            className="button button--filled button--small topbar-download"
            type="button"
            onClick={handleDownload}
          >
            Download
          </button>
          <button
            className="icon-button menu-toggle"
            type="button"
            onClick={onToggleMenu}
            aria-label={menuOpen ? "Close menu" : "Open menu"}
            aria-expanded={menuOpen}
            aria-controls="mobileMenu"
          >
            <Icon name={menuOpen ? "close" : "menu"} />
          </button>
        </div>
      </div>

      <div className="mobile-menu" id="mobileMenu" hidden={!menuOpen}>
        <nav aria-label="Mobile">
          {navItems.map((item) => (
            <a key={item.href} href={item.href} onClick={onCloseMenu}>
              {item.label}
            </a>
          ))}
        </nav>
        <button className="button button--filled" type="button" onClick={handleDownload}>
          Download for macOS
        </button>
      </div>
    </header>
  );
}
