---
title: Contributing
sidebar_position: 3
description: How the library repository is laid out and how to contribute packages, plugins, blocks, guides or fixes.
---

# Contributing

The library is one repository, [github.com/KashTheKing/library](https://github.com/KashTheKing/library), and this site is built from it. Fixes, new guides and improvements to any package are welcome as pull requests.

## Repository layout

| Folder | Holds | Shows up as |
| --- | --- | --- |
| `packages/src/<Name>/` | One Wally package per folder: `init.luau`, `wally.toml`, `README.md`, optional helpers | [Packages](../packages/index.md) pages and the [API reference](/api/) |
| `plugins/<name>/` | A README per Studio plugin (plugin source is not in this repo) | [Plugins](../plugins/index.md) pages |
| `building-blocks/` | `.rbxm` files with a README each | [Building Blocks](../building-blocks/index.md) pages |
| `guides/` | Guide sources as READMEs | [Guides](./index.md) |
| `docs/` | This site's Markdown pages | Everything under Docs |
| `pages/`, `.moonwave/`, `moonwave.toml` | Site home page, theme and config | The site itself |

## Making a change

1. Fork the repository and create a branch.
2. Make the change:
   - **A package fix:** edit `packages/src/<Name>/init.luau`. Keep the `--!strict` header and the existing code style (tabs, PascalCase methods). Bump `version` in `wally.toml` following semver, and update the version in the package's `README.md` and in `docs/packages/<name>.md`.
   - **API docs:** the API reference is generated from `--[=[ ... ]=]` doc comments in the source, in [Moonwave](https://eryn.io/moonwave/) syntax. Methods written as `function Class.Name(self: Class, ...)` need an explicit `@method Name` and `@within Class` tag. Every parameter gets `@param`, every return `@return`.
   - **A docs page:** edit the file under `docs/`. Every page on the site has an **Edit this page** link at the bottom that opens the right file on GitHub.
   - **A guide:** add `docs/guides/<slug>.md` with the front matter the other guides use, and add a card to `docs/guides/index.md`.
3. Open a pull request describing what changed and why. Small, focused PRs get merged fastest.

## Building the site locally

The site is a [Moonwave](https://eryn.io/moonwave/) project. With Node.js installed:

```bash
npm install
npm run docs:dev      # live-reloading preview at http://localhost:3000/library/
npm run docs:build    # static build in build/docs
```

`docs:dev` and `docs:build` pass `--code packages/src`, which is where Moonwave reads the doc comments. A doc comment error fails the build with the file and line, so run a build before you push.

## How things get published

- **Packages** are published to Wally by me with `wally publish` from the package folder after a version bump. Open a PR with the bump and I will publish.
- **The site** is built with `npm run publish:docs`, which runs the Moonwave build and commits the output into the `library/` folder of [KashTheKing.github.io](https://github.com/KashTheKing/kashtheking.github.io), served at [kashtheking.com/library](https://kashtheking.com/library/). Same flow as the Infinite Ocean docs.
- **Plugins** are published to the Creator Store from Studio; their source is not in this repository, so plugin issues are best reported as GitHub issues or on Discord.

## Reporting rather than fixing

Not every contribution has to be code. A clear bug report with a reproduction, a note that a page is confusing, or a request for a guide is just as useful: open a [GitHub issue](https://github.com/KashTheKing/library/issues) or post in the [Discord](https://discord.gg/6HYgCk22eD).

## Licence

By contributing you agree your contribution is released under the repository's [MIT licence](https://github.com/KashTheKing/library/blob/main/LICENSE).
