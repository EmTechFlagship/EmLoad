# EmLoad Website

Marketing and download site for EmLoad — a native macOS app that sideloads IPAs with a free Apple ID.

Built with **React 19 + TypeScript + Vite**. All UI is written in TSX; there is no hand-authored page markup beyond the Vite entry shell. Styling is custom CSS implementing Material 3 Expressive tokens, components, and motion.

## Requirements

- Node.js 20+ (developed on Node 26)
- npm 10+

## Development

```sh
npm install
npm run dev
```

The dev server runs at <http://localhost:5173>.

## Build

```sh
npm run build     # type-check with tsc, then bundle with Vite
npm run preview   # serve the production build locally
npm run typecheck # type-check only
```

The production site is written to `dist/`. `vite.config.ts` sets `base: "./"`, so the build is portable and can be served from any static host or subdirectory.

## Deployment

Upload the contents of `dist/` to any static host (Vercel, Cloudflare Pages, Netlify, S3, nginx, …). No server-side runtime is required.

Because the site is a single-page app, only `index.html` needs to be served for `/`; there are no client-side routes.

## Project structure

```
Website/
├── index.html                 # Vite entry shell: meta tags, theme bootstrap, fonts
├── public/
│   ├── assets/                # App icon, favicon, hero app screenshot
│   └── downloads/             # macOS DMG builds served by the site
├── src/
│   ├── App.tsx                # Page composition and shared state
│   ├── main.tsx               # React root
│   ├── styles.css             # Material 3 Expressive tokens and all styling
│   ├── types.ts               # Shared TypeScript types
│   ├── data/site.ts           # Version, download URLs, nav/FAQ/step content
│   ├── components/            # Page sections and UI primitives
│   └── hooks/                 # Theme, reveal, platform detection, scroll
└── vite.config.ts
```

## Updating the app version and downloads

1. Build the new macOS release (see `../gui-macos/README.md`).
2. Copy the DMGs into `public/downloads/` using the same naming pattern:
   - `EmLoad-<version>-macos.dmg` (universal)
   - `EmLoad-<version>-macos-arm64.dmg` (Apple silicon)
   - `EmLoad-<version>-macos-x86_64.dmg` (Intel)
3. Update the paths in `src/data/site.ts` under `site.downloads`.
4. Update `site.version` and `site.shortVersion`, plus any size/version copy in
   `src/components/Hero.tsx`, `src/components/DownloadPanel.tsx`, and
   `src/components/DownloadDialog.tsx`.
5. Delete the previous DMGs so the bundle does not keep growing.
6. Run `npm run build` and spot-check the download buttons.

DMGs are kept in `public/` so downloads work without depending on an external release host.

## Design notes

- **Material 3 Expressive**: custom token set (color roles, shape scale, elevation, motion easing) in `src/styles.css`, with light and dark palettes.
- **Theme**: follows `prefers-color-scheme` on first visit, then persists the user's choice in `localStorage` (`emload-theme`). An inline script in `index.html` applies the theme before first paint to avoid a flash.
- **Architecture detection**: `usePlatform` uses `navigator.userAgentData.getHighEntropyValues()` where available, falls back to the WebGL renderer string, and otherwise shows no recommendation.
- **Accessibility**: skip link, keyboard-operable menu and FAQ, visible focus rings, labeled icon buttons, and `prefers-reduced-motion` support.
- **No tracking**: the site makes no analytics or third-party requests beyond Google Fonts.
- **Closed source**: EmLoad is proprietary, so the site intentionally has no repository, source-code, or release-page links — only direct downloads.

## License

EmLoad is closed-source software. This website and its assets are © EmLoad. EmLoad is not affiliated with Apple Inc.
