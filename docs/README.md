# chartplotter-native documentation

This is the source for the chartplotter-native documentation site. It is built
with [Docusaurus](https://docusaurus.io/) and shares the look of the
[chartplotter-go docs](https://beetlebugorg.github.io/chartplotter/).

## Develop

Install dependencies and start a local server with live reload:

```sh
npm install
npm start
```

## Build

Generate the static site into `build/`:

```sh
npm run build
npm run serve   # preview the production build
```

The content pages live under `docs/`; the sidebar order is in `sidebars.js`.
