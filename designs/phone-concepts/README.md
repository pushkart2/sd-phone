# Paper × Mosaic phone study

Open `index.html` directly in a browser. No installation or build is needed. The file contains its own styles, scripts, and SVG icons, and does not load the production phone UI.

The default view combines Paper’s typographic app list with Mosaic’s palette, comparing light and dark modes side by side.

| Color | Light | Dark |
| --- | --- | --- |
| Background | Lavender `#f1edf5` | Aubergine `#1c1822` |
| Text | Plum `#30243b` | Chalk `#eee9f4` |
| Secondary text | `#6e5d79` | `#b1a6be` |
| Accent | Violet `#755494` | Lilac `#b8a1d8` |
| Surface | `#e5dced` | `#302638` |

Use the **Light / Dark** controls above either phone, or go to **Apps → Settings → Appearance**. The mode updates all example screens and keeps the current screen, conversation, and typed draft. Each phone has its own mode for comparison. Reloading returns to the initial light/dark pair.

Use **Inspect** to view one design, or **All designs** to return to the comparison. Messages, Phone, Bank, Music, Maps, Notes, app search, and the bottom navigation are interactive examples. Other apps are placeholders. Sending messages and playing music change only local preview state; no server, game, banking, or audio services are connected. Reloading resets the fictional data.

Individual views can be opened using `index.html?concept=paper-mosaic-light` and `index.html?concept=paper-mosaic-dark`.

The first three designs are preserved at `index.html?collection=original`: Signal (graphite/orange grid), Paper (chalk/olive list), and Mosaic (aubergine/lilac tiles). Their original `?concept=signal`, `?concept=paper`, and `?concept=mosaic` links still work.

Screenshots are saved in `screenshots/`. These concepts are for review only; they do not register with FiveM or modify the existing phone.

To refresh the screenshots and run the preview checks, run `node designs/phone-concepts/capture.mjs` from the repository root. This uses the already-installed Playwright dependency and Chrome; it does not install packages.
