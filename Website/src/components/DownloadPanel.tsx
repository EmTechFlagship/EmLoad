import { downloadOptions, site } from "../data/site";
import type { Arch } from "../types";
import { Icon } from "./Icon";

interface DownloadPanelProps {
  arch: Arch | null;
}

export function DownloadPanel({ arch }: DownloadPanelProps) {
  return (
    <section className="section section--download" id="download">
      <div className="container">
        <div className="download-panel reveal">
          <div className="download-glow" aria-hidden="true" />

          <div className="download-copy">
            <span className="section-kicker section-kicker--light">Get EmLoad</span>
            <h2 aria-label="Your iPhone. Your apps. Your call.">
              Your iPhone.
              <br />
              Your apps.
              <br />
              <span className="accent-lime-text">Your call.</span>
            </h2>
            <p>
              Download the beta, drag it to Applications, and sideload your first IPA today.
            </p>
            <div className="download-actions">
              <a
                className="button button--light button--xl"
                href={site.downloads.universal}
                download
              >
                <Icon name="apple" />
                Download for macOS
              </a>
            </div>
            <p className="download-fine">
              {site.shortVersion} · Universal DMG · 36 MB · macOS 26+
            </p>
          </div>

          <div className="download-options">
            {downloadOptions.map((option) => (
              <a
                className="download-card"
                href={option.href}
                download
                key={option.arch}
                data-arch={option.arch}
              >
                <span className="download-card-icon">
                  <Icon name={option.icon} />
                </span>
                <span className="download-card-copy">
                  <strong>
                    {option.title}
                    {option.recommended ? (
                      <span className="tag tag--lime">Recommended</span>
                    ) : arch === option.arch ? (
                      <span className="tag tag--detect">Your Mac</span>
                    ) : null}
                  </strong>
                  <small>{option.detail}</small>
                </span>
                <span className="download-card-arrow">
                  <Icon name="download" />
                </span>
              </a>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
