import { useEffect, useRef } from "react";
import { downloadOptions, site } from "../data/site";
import type { Arch } from "../types";
import { Icon } from "./Icon";

interface DownloadDialogProps {
  open: boolean;
  arch: Arch | null;
  onClose: () => void;
}

export function DownloadDialog({ open, arch, onClose }: DownloadDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;

    if (open && !dialog.open) {
      dialog.showModal();
      document.body.classList.add("dialog-open");
    } else if (!open && dialog.open) {
      dialog.close();
    }

    return () => {
      document.body.classList.remove("dialog-open");
    };
  }, [open]);

  return (
    <dialog
      className="download-dialog"
      id="downloadDialog"
      ref={dialogRef}
      aria-labelledby="downloadDialogTitle"
      onClose={onClose}
      onClick={(event) => {
        if (event.target === dialogRef.current) onClose();
      }}
    >
      <form method="dialog" className="dialog-card">
        <div className="dialog-head">
          <div>
            <span className="section-kicker">Download EmLoad</span>
            <h2 id="downloadDialogTitle">Choose your Mac.</h2>
            <p>Version {site.version} · macOS 26 Tahoe or newer</p>
          </div>
          <button
            className="icon-button"
            type="submit"
            value="cancel"
            aria-label="Close download options"
          >
            <Icon name="close" />
          </button>
        </div>

        <div className="dialog-options">
          {downloadOptions.map((option) => (
            <a
              className="dialog-option"
              href={option.href}
              download
              key={option.arch}
              data-arch={option.arch}
              onClick={onClose}
            >
              <span className="dialog-option-icon">
                <Icon name={option.icon} />
              </span>
              <span className="dialog-option-copy">
                <strong>{option.title}</strong>
                <small>{option.detail}</small>
              </span>
              {option.recommended ? (
                <span className="tag tag--lime">Recommended</span>
              ) : arch === option.arch ? (
                <span className="tag tag--detect">Your Mac</span>
              ) : null}
            </a>
          ))}
        </div>

        <div className="dialog-note">
          <Icon name="info" />
          <span>
            Beta builds are ad-hoc signed, not notarized. On first launch, right-click the
            app and choose <strong>Open</strong>.
          </span>
        </div>

        <div className="dialog-foot">
          <span>Free · No account required</span>
        </div>
      </form>
    </dialog>
  );
}
