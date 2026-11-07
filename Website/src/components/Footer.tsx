export function Footer() {
  const year = new Date().getFullYear();

  return (
    <footer className="footer">
      <div className="container footer-inner">
        <div className="footer-brand">
          <a className="brand" href="#top" aria-label="EmLoad home">
            <img
              className="brand-mark"
              src="assets/emload-icon.png"
              alt=""
              width={36}
              height={36}
            />
            <span className="brand-name">EmLoad</span>
          </a>
          <p>
            Sideload iOS apps with a free Apple ID. No jailbreak. No paid developer account.
          </p>
        </div>

        <div className="footer-links">
          <a href="#features">Features</a>
          <a href="#how">How it works</a>
          <a href="#requirements">Requirements</a>
          <a href="#faq">FAQ</a>
        </div>

        <p className="footer-legal">
          EmLoad is an independent project and is not affiliated with Apple Inc. Apple,
          iPhone, iPad, and macOS are trademarks of Apple Inc. Use at your own risk and only
          with apps you have the right to install.
        </p>
        <p className="footer-copy">
          © {year} EmLoad. Built for people who like owning their devices.
        </p>
      </div>
    </footer>
  );
}
