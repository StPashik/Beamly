# Beamly landing page

Buildless Russian and English presentation site. Serve this directory with any static HTTP server, for example `python3 -m http.server 4173 --directory Website` from the repository root. `index.html` is Russian; `en.html` is English. Both pages share styles and interactions.

The header's RU / EN links work without JavaScript. With JavaScript, the chosen language is remembered in local storage. The default Russian entry opens English when it was previously selected; explicit `?lang=ru` or `?lang=en` links take precedence, and direct English links stay English. If storage is unavailable, switching still works without persistence.

The player and feature panels are explicitly labeled illustrations; they do not connect to devices or play video. Download links point to the latest GitHub release. No analytics, external fonts, runtime dependencies, or personal media are included.

Both languages share a short hero entrance, a single soft TV glow animation, and transitions when switching feature panels. Headings, the setup steps, feature blocks, privacy panel, FAQ, and download section also enter once when scrolled into view; the three setup steps and feature highlights are staggered. A native IntersectionObserver triggers these CSS animations without a scroll handler. Content stays visible without JavaScript or observer support, keyboard focus skips the reveal, and `prefers-reduced-motion` disables the effects. There are no continuous animation loops.

Run the focused interaction checks with `node --test Website/script.test.cjs`. Verify the desktop and mobile layout in a browser after changing markup or styles.

## Hosting

The Sites identity is retained in `.openai/hosting.json`. For publication, copy that manifest plus `index.html`, `en.html`, `styles.css`, `script.js`, and `assets/` into a separate Sites source checkout, placing the page files in `dist/`. Keep deployment archives, credentials, and the hosting repository's Git metadata outside this application repository. The native application follows GitFlow; website changes also target `develop` through a feature pull request.

## Assets

- `assets/beamly-icon.png`: web-sized copy of the project's original `Resources/AppIcon.png`, under the project license.
- `assets/cinema.jpg`: original landscape generated with the built-in Imagegen tool, then encoded as JPEG for the web.

Image generation prompt: “Use case: photorealistic-natural. Asset type: widescreen landscape image used inside a CSS television mockup for the Beamly landing page. Primary request: widescreen cinematic aerial still of a rugged alpine mountain ridge and deep forest overlooking a turquoise glacial lake at blue hour. Distant mist, a small warm sunrise at the horizon, rich natural teal and charcoal palette. Premium film photography, realistic texture and atmospheric depth, tranquil dramatic mood. Composition: 16:9 landscape, large lake in lower center, mountain ridge in upper half. Constraints: no text, no logos, no people, no devices, no border, no watermark.”
