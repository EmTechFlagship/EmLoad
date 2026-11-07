import { useEffect, useRef } from "react";
import { marqueeItems, site } from "../data/site";
import { Icon } from "./Icon";

interface HeroProps {
  onDownload: () => void;
}

export function Hero({ onDownload }: HeroProps) {
  const artRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const element = artRef.current;
    if (!element) return;

    const finePointer = window.matchMedia("(pointer: fine)").matches;
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!finePointer || reducedMotion) return;

    let frame = 0;

    const onMove = (event: PointerEvent) => {
      const rect = element.getBoundingClientRect();
      const x = (event.clientX - rect.left) / rect.width - 0.5;
      const y = (event.clientY - rect.top) / rect.height - 0.5;
      window.cancelAnimationFrame(frame);
      frame = window.requestAnimationFrame(() => {
        element.style.setProperty("--rx", `${(-y * 5).toFixed(2)}deg`);
        element.style.setProperty("--ry", `${(x * 6).toFixed(2)}deg`);
      });
    };

    const onLeave = () => {
      window.cancelAnimationFrame(frame);
      element.style.setProperty("--rx", "0deg");
      element.style.setProperty("--ry", "0deg");
    };

    element.addEventListener("pointermove", onMove);
    element.addEventListener("pointerleave", onLeave);

    return () => {
      window.cancelAnimationFrame(frame);
      element.removeEventListener("pointermove", onMove);
      element.removeEventListener("pointerleave", onLeave);
    };
  }, []);

  return (
    <section className="hero" id="top">
      <div className="hero-bg" aria-hidden="true">
        <span className="blob blob--blue" />
        <span className="blob blob--pink" />
        <span className="blob blob--lime" />
        <span className="dot-field" />
      </div>

      <div className="container hero-inner">
        <div className="hero-copy">
          <div className="eyebrow">
            <span className="pulse" aria-hidden="true" />
            <span>{site.shortVersion}</span>
            <span className="eyebrow-sep" aria-hidden="true" />
            <span>macOS 26+</span>
          </div>

          <h1 aria-label="Sideload anything. Keep your freedom.">
            Sideload anything.
            <br />
            <span className="accent">Keep your freedom.</span>
          </h1>

          <p className="lede">
            EmLoad installs any <strong>.ipa</strong> on your iPhone with a{" "}
            <strong>free Apple ID</strong> — no jailbreak, no paid developer account. A
            native macOS app that stays out of your way.
          </p>

          <div className="hero-actions">
            <div className="split-button">
              <a className="split-main" href={site.downloads.universal} download>
                <Icon name="apple" />
                Download for macOS
              </a>
              <button
                className="split-toggle"
                type="button"
                onClick={onDownload}
                aria-haspopup="dialog"
                aria-label="More download options"
              >
                <Icon name="chevron-down" />
              </button>
            </div>
            <a className="button button--outlined button--xl" href="#how">
              How it works
              <Icon name="arrow-right" />
            </a>
          </div>

          <div className="hero-meta">
            <span className="meta-item">
              <Icon name="check" /> Free Apple ID
            </span>
            <span className="meta-item">
              <Icon name="check" /> USB + Wi-Fi
            </span>
            <span className="meta-item">
              <Icon name="check" /> 7-day refresh
            </span>
          </div>

          <p className="hero-fine">
            Universal build for Apple silicon &amp; Intel · 36 MB · Ad-hoc signed beta
          </p>
        </div>

        <div className="hero-art" ref={artRef}>
          <div className="sticker sticker--refresh" aria-hidden="true">
            <span>7-day</span>
            <strong>refresh</strong>
          </div>

          <img
            className="app-shot"
            src="assets/emload-app-devices.png"
            alt=""
            width={1240}
            height={886}
            fetchPriority="high"
            decoding="async"
          />

          <div className="float-chip float-chip--a">
            <Icon name="wifi" /> USB + Wi-Fi
          </div>
          <div className="float-chip float-chip--b">
            <Icon name="shield" /> Apple ID stays local
          </div>
        </div>
      </div>

      <div className="hero-marquee" aria-hidden="true">
        <div className="marquee-track">
          {[0, 1].map((group) => (
            <div className="marquee-group" key={group}>
              {marqueeItems.map((item) => (
                <span key={`${group}-${item}`}>{item}</span>
              ))}
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
