import { CopyButton } from "./CopyButton";
import { Icon } from "./Icon";

const setupCommands = `python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m emload setup
.venv/bin/python -m emload doctor`;

export function Requirements() {
  return (
    <section className="section" id="requirements">
      <div className="container">
        <div className="section-head reveal">
          <span className="section-kicker">Before you install</span>
          <h2>Check your Mac.</h2>
          <p>
            EmLoad is a small native shell around the EmLoad Python engine. Here's what it
            needs.
          </p>
        </div>

        <div className="req-grid">
          <div className="req-card reveal">
            <h3>Requirements</h3>
            <ul className="req-list">
              <li>
                <span className="req-check">
                  <Icon name="check" />
                </span>
                <span>
                  <strong>macOS 26 Tahoe</strong> or newer
                </span>
              </li>
              <li>
                <span className="req-check">
                  <Icon name="check" />
                </span>
                <span>
                  <strong>Apple silicon or Intel</strong> Mac
                </span>
              </li>
              <li>
                <span className="req-check">
                  <Icon name="check" />
                </span>
                <span>
                  <strong>Python 3.10+</strong> with the engine dependencies
                </span>
              </li>
              <li>
                <span className="req-check">
                  <Icon name="check" />
                </span>
                <span>
                  <strong>iPhone or iPad</strong> with Developer Mode enabled and a trusted
                  pairing
                </span>
              </li>
              <li>
                <span className="req-check">
                  <Icon name="check" />
                </span>
                <span>
                  <strong>A free Apple ID</strong> — a spare one is a good idea
                </span>
              </li>
            </ul>

            <div className="req-note">
              <Icon name="info" />
              <span>
                EmLoad includes <code>zsign</code> for this Mac. The Python dependencies are
                a one-time terminal setup.
              </span>
            </div>
          </div>

          <div className="req-card req-card--setup reveal">
            <div className="req-card-head">
              <h3>One-time engine setup</h3>
              <span className="tag tag--lime">Terminal</span>
            </div>
            <p className="req-copy">
              If the app reports missing Python packages, point it at a virtual environment
              with the requirements installed.
            </p>

            <div className="code-panel">
              <div className="code-panel-head">
                <span>
                  <Icon name="terminal" /> Terminal
                </span>
                <CopyButton
                  text={setupCommands}
                  className="copy-btn copy-btn--ghost"
                  label="Copy"
                />
              </div>
              <pre>
                <code>
                  <span className="prompt">$</span> python3 -m venv .venv{"\n"}
                  <span className="prompt">$</span> .venv/bin/python -m pip install -r
                  requirements.txt{"\n"}
                  <span className="prompt">$</span> .venv/bin/python -m emload setup{"\n"}
                  <span className="prompt">$</span> .venv/bin/python -m emload doctor
                </code>
              </pre>
            </div>

            <p className="req-foot">
              Then set <code>EMLOAD_PYTHON</code> to that interpreter when launching EmLoad.
            </p>
          </div>
        </div>

        <div className="notice reveal">
          <span className="notice-icon">
            <Icon name="warning" />
          </span>
          <div>
            <h3>First launch: right-click → Open</h3>
            <p>
              Beta builds are ad-hoc signed, not notarized. If macOS blocks the first
              launch, open <strong>System Settings → Privacy &amp; Security</strong> and
              choose <strong>Open Anyway</strong>. You only need to do this once.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
