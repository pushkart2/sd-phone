# Paper / Cream & charcoal phone study

Open `index.html` directly in a browser. No installation or build is needed. The file contains its own styles, scripts, and SVG icons, and does not load the production phone UI.

The default view uses Paper’s original warm cream and olive palette, with a contrasting charcoal-olive dark mode. Paper’s clock, reminder, and quiet typography are retained. Apps use a familiar four-column icon grid on both the home screen and app drawer. The icon family uses consistent line artwork, soft sage tiles in light mode, muted olive tiles in dark mode, and a highlighted Messages icon with an unread badge.

| Color | Light | Dark |
| --- | --- | --- |
| Background | Cream `#f2f1e8` | Charcoal-olive `#20231e` |
| Text | Olive `#283728` | Cream `#f2f1e8` |
| Secondary text | `#606653` | `#b6baab` |
| Accent | Moss `#516642` | Sage `#bdc9a7` |
| Surface | `#e6e9dc` | `#30362b` |

Use the **Light / Dark** controls above either phone, or go to **Apps → Settings → Appearance**. The mode updates all example screens and keeps the current screen, conversation, and typed draft. Each phone has its own mode for comparison. Reloading returns to the initial light/dark pair.

Use **Inspect** to view one design, or **All designs** to return to the comparison. Messages, Phone, Bank, Music, Maps, Notes, app search, and the bottom navigation are interactive examples. Other apps are placeholders. Sending messages and playing music change only local preview state; no server, game, banking, or audio services are connected. Reloading resets the fictional data.

Individual views can be opened using `index.html?concept=paper-mosaic-light` and `index.html?concept=paper-mosaic-dark`. The existing concept IDs and screenshot filenames are kept so previously shared links continue to work.

The first three designs are preserved at `index.html?collection=original`: Signal (graphite/orange grid), Paper (chalk/olive list), and Mosaic (aubergine/lilac tiles). Their original `?concept=signal`, `?concept=paper`, and `?concept=mosaic` links still work.

Screenshots are saved in `screenshots/`. These concepts are for review only; they do not register with FiveM or modify the existing phone.

To refresh the screenshots and run the preview checks, run `node designs/phone-concepts/capture.mjs` from the repository root. This uses the already-installed Playwright dependency and Chrome; it does not install packages.
