# Beamly landing page

Buildless Russian presentation site. Serve this directory with any static HTTP server, for example `python3 -m http.server 4173 --directory Website` from the repository root.

The player and feature panels are explicitly labeled illustrations; they do not connect to devices or play video. Download links point to the latest GitHub release. No analytics, external fonts, runtime dependencies, or personal media are included.

Run the focused interaction checks with `node --test Website/script.test.cjs`. Verify the desktop and mobile layout in a browser after changing markup or styles.

## Hosting

The Sites identity is retained in `.openai/hosting.json`. For publication, copy that manifest plus `index.html`, `styles.css`, `script.js`, and `assets/` into a separate Sites source checkout, placing the page files in `dist/`. Keep deployment archives, credentials, and the hosting repository's Git metadata outside this application repository. The native application follows GitFlow; website changes also target `develop` through a feature pull request.

## Assets

- `assets/beamly-icon.png`: web-sized copy of the project's original `Resources/AppIcon.png`, under the project license.
- `assets/cinema.jpg`: original landscape generated with the built-in Imagegen tool, then encoded as JPEG for the web.

Image generation prompt: “Use case: photorealistic-natural. Asset type: widescreen landscape image used inside a CSS television mockup for the Beamly landing page. Primary request: widescreen cinematic aerial still of a rugged alpine mountain ridge and deep forest overlooking a turquoise glacial lake at blue hour. Distant mist, a small warm sunrise at the horizon, rich natural teal and charcoal palette. Premium film photography, realistic texture and atmospheric depth, tranquil dramatic mood. Composition: 16:9 landscape, large lake in lower center, mountain ridge in upper half. Constraints: no text, no logos, no people, no devices, no border, no watermark.”
