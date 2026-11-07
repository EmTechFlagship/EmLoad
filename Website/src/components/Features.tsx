import { CopyButton } from "./CopyButton";
import { Icon } from "./Icon";

export function Features() {
  return (
    <section className="section" id="features">
      <div className="container">
        <div className="section-head reveal">
          <span className="section-kicker">Everything you need</span>
          <h2>
            Small app. <span className="accent-2">Serious toolkit.</span>
          </h2>
          <p>
            One native window for signing, installing, refreshing, and debugging — powered
            by the same engine as the EmLoad CLI.
          </p>
        </div>

        <div className="bento">
          <article className="card card--primary reveal">
            <div className="card-icon">
              <Icon name="key" />
            </div>
            <h3>Your Apple ID, in-process</h3>
            <p>
              GrandSlam SRP-6a sign-in over pinned TLS. Your password, 2FA code, and session
              tokens never leave your Mac — and they aren't stored anywhere.
            </p>
            <div className="mini-auth">
              <div className="mini-field">
                <Icon name="user" /> you@icloud.com
              </div>
              <div className="mini-field">
                <Icon name="lock" /> <span className="dots">••••••••••</span>
              </div>
              <div className="mini-auth-row">
                <span className="mini-code">2FA •••</span>
                <span className="mini-submit">
                  Sign in <Icon name="arrow-right" />
                </span>
              </div>
            </div>
          </article>

          <article className="card card--refresh reveal">
            <div className="card-icon">
              <Icon name="refresh" />
            </div>
            <h3>Never miss a refresh</h3>
            <p>
              Free Apple IDs sign apps for seven days. EmLoad tracks every expiry and
              re-signs before it runs out.
            </p>
            <div className="ring-wrap">
              <div
                className="ring"
                role="img"
                aria-label="Five days left on the current signature"
              >
                <span className="ring-inner">
                  <strong>5</strong>
                  <small>days left</small>
                </span>
              </div>
              <span className="ring-action">
                <Icon name="refresh" /> Refresh all
              </span>
            </div>
          </article>

          <article className="card card--device reveal">
            <div className="card-icon">
              <Icon name="phone" />
            </div>
            <h3>Wired or wireless</h3>
            <p>
              Install over USB or Wi-Fi through <code>usbmuxd</code>. Your phone shows up
              the moment it's trusted.
            </p>
            <div className="device-art" aria-hidden="true">
              <span className="phone phone--muted" />
              <span className="device-link">
                <Icon name="plug" />
                <Icon name="wifi" />
              </span>
              <span className="phone phone--active" />
            </div>
          </article>

          <article className="card card--jit reveal">
            <div className="card-icon">
              <Icon name="bolt" />
            </div>
            <h3>JIT when you need it</h3>
            <p>
              Attach the debugger, detach, and keep just-in-time compilation until the app
              quits.
            </p>
            <div className="toggle-row">
              <span>Enable JIT</span>
              <span className="switch is-on" aria-hidden="true">
                <i />
              </span>
            </div>
          </article>

          <article className="card card--privacy reveal">
            <div className="card-icon">
              <Icon name="shield" />
            </div>
            <h3>Private by default</h3>
            <p>Everything runs on your Mac. No account servers, no analytics, no telemetry.</p>
            <ul className="mini-list">
              <li>
                <Icon name="check" /> Tokens stay local
              </li>
              <li>
                <Icon name="check" /> No EmLoad servers
              </li>
              <li>
                <Icon name="check" /> No jailbreak required
              </li>
            </ul>
          </article>

          <article className="card card--nugget reveal">
            <div className="card-icon">
              <Icon name="sparkles" />
            </div>
            <h3>More than sideloading</h3>
            <p>
              Optional Nugget-based tweaks for SpringBoard, daemons, and Liquid Glass on
              supported iOS versions.
            </p>
            <div className="tweak-list">
              <div className="tweak-row">
                <span className="tweak-dot" /> SpringBoard options
                <span className="tweak-state">On</span>
              </div>
              <div className="tweak-row">
                <span className="tweak-dot" /> Daemon toggles
                <span className="tweak-state">On</span>
              </div>
              <div className="tweak-row">
                <span className="tweak-dot" /> Liquid Glass
                <span className="tweak-state">On</span>
              </div>
            </div>
          </article>

          <article className="card card--cli reveal">
            <div className="card-icon">
              <Icon name="terminal" />
            </div>
            <h3>Same engine, two ways</h3>
            <p>Prefer the terminal? The CLI ships with every install.</p>
            <div className="terminal">
              <div className="terminal-bar">
                <i />
                <i />
                <i />
                <span>zsh — emload</span>
                <CopyButton
                  text="emload install MyApp.ipa"
                  className="copy-btn copy-btn--inline"
                  label="Copy"
                />
              </div>
              <pre>
                <code>
                  <span className="prompt">$</span> emload install MyApp.ipa{"\n"}
                  <span className="term-ok">✓</span> signed · installed · 7 days
                </code>
              </pre>
            </div>
          </article>
        </div>
      </div>
    </section>
  );
}
