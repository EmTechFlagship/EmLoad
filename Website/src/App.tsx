import { useEffect, useState } from "react";
import { BackToTop } from "./components/BackToTop";
import { DownloadDialog } from "./components/DownloadDialog";
import { DownloadPanel } from "./components/DownloadPanel";
import { Faq } from "./components/Faq";
import { Features } from "./components/Features";
import { Footer } from "./components/Footer";
import { Hero } from "./components/Hero";
import { HowItWorks } from "./components/HowItWorks";
import { IconSprite } from "./components/IconSprite";
import { Requirements } from "./components/Requirements";
import { TopBar } from "./components/TopBar";
import { usePlatform } from "./hooks/usePlatform";
import { useReveal } from "./hooks/useReveal";
import { useTheme } from "./hooks/useTheme";

export default function App() {
  const { theme, toggleTheme } = useTheme();
  const arch = usePlatform();
  const [downloadOpen, setDownloadOpen] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);

  useReveal();

  useEffect(() => {
    const onResize = () => {
      if (window.innerWidth > 960) setMenuOpen(false);
    };
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  const openDownload = () => setDownloadOpen(true);

  return (
    <>
      <IconSprite />
      <a className="skip-link" href="#main">
        Skip to content
      </a>

      <TopBar
        theme={theme}
        menuOpen={menuOpen}
        onToggleTheme={toggleTheme}
        onToggleMenu={() => setMenuOpen((open) => !open)}
        onCloseMenu={() => setMenuOpen(false)}
        onDownload={openDownload}
      />

      <main id="main">
        <Hero onDownload={openDownload} />
        <Features />
        <HowItWorks />
        <Requirements />
        <Faq />
        <DownloadPanel arch={arch} />
      </main>

      <Footer />
      <BackToTop />
      <DownloadDialog
        open={downloadOpen}
        arch={arch}
        onClose={() => setDownloadOpen(false)}
      />
    </>
  );
}
