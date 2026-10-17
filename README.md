# HexoMan

> **A native macOS manager for Hexo sites.** Add sites, write posts, generate previews, edit configs, manage Git — all in one SwiftUI window. Your posts and configs stay as plain Markdown and YAML on disk; HexoMan keeps no separate database.

Hexo is fast and the Markdown stays yours, but the day-to-day work — open a project, write a post, edit `_config.yml`, run `hexo g`, push to GitHub — means juggling four terminals and one editor. HexoMan folds it all into one window.

![Platform](https://img.shields.io/badge/Platform-macOS%2026%2B-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

[中文文档](./README.zh-CN.md) · [Releases](https://github.com/Mofan2020/HexoMan/releases)

<!-- Screenshot: drop a screenshot into docs/screenshot-overview.png and replace this comment
![Overview](docs/screenshot-overview.png) -->

## Features

A sidebar on the left switches sites and sections; the right pane holds the content. All sections except "Sites" require a selected site.

### Sites

- Add a site by picking its directory or pasting its absolute path.
- A directory qualifies as a site when it contains `package.json` (declaring `hexo`) and `_config.yml`.
- Multiple sites coexist, sorted by last-opened time; one click switches.
- Reveal in Finder or remove from list (list-only — disk files are never touched).
- The current site cannot be removed until you switch to another one.

### Overview

- Five metric cards: post count, Hexo version, theme + theme version, build artifact file count, dependencies installed.
- If dependencies are missing, actionable hints and an "Open site folder" button.
- Site detail: site path, Hexo source, command preview, Git repo status, remote URL, preview port.
- Quick actions: generate site, clean, start/stop preview, open preview in browser, reveal in Finder, refresh Git status.
- Five most recent commits, one-click jump to full Git log.

### Posts

- List on the left, detail on the right; searchable by title, body, and tags.
- Filter by all / published / drafts.
- New post: pick title, tags, categories, then go straight into the editor.
- Editor edits title, date, tags, categories, draft toggle, and body; live word count.
- Detail page shows date, word count, file size, slug, filename, last-modified, tags, categories.
- One-click publish / convert to draft (flips `draft` in front-matter).
- Delete goes to the Trash — recoverable.
- Reveal in Finder.

### Build & Preview

- Top section shows the build environment: site path, Hexo source, exact command line to be executed.
- Runs `hexo clean` and `hexo generate`.
- Start/stop the local preview server; configurable port (1024–65535); shows the preview URL.
- One-click open preview in browser, open `public` in Finder.
- Shows build artifact status and file count.
- Lower half is a live log console with a clear button.

### Config

- Lists and edits every `_config*.yml` in the site root (main config first, theme configs sorted by name).
- Top-key shortcut bar: click a key to jump and select that row.
- Pre-save validation: empty content, contains Tab, indent is not a multiple of spaces — all warn before saving.
- Discard changes, re-read from disk, reveal in Finder.

### Git

- Repo status: current branch, ahead/behind counts, upstream, `git status` summary.
- Changed files grouped by staged / modified / untracked, each row has `[+/− stage]` and `[diff]` buttons; single-file stage, unstage, difftool.
- When `diff.tool` is not configured, `[diff]` falls back to opening the file in the system default editor (Xcode/VSCode/etc).
- Commit message + "Commit all changes" (runs `git add -A` then commit, including untracked files).
- Pull (`git pull --rebase`), push (button disabled when there's nothing to push).
- Remotes list.
- Commit history list (short hash, title, author, date).
- Lower log console shows real `git` output.
- When the site is not a Git repo, shows a one-click "copy `git init` to clipboard" hint.

### Themes

- Browse the official theme library (HexoMan picks + every `hexo-theme-*` on npm); one-click preview the official site (embedded WKWebView) + install.
- Theme install auto-runs cross-theme migration — common items like avatar / favicon move from the old theme to the new one (when the new theme supports them), so changing themes never silently wipes your config.
- Package name normalization: `yun`, `hexo-theme-yun`, `@scope/hexo-theme-yun` all install correctly — no double `hexo-theme-hexo-theme-yun` accidents.
- Error states show specific reasons, not just "see log".
- Diagnostics: which items can be auto-fixed, which need manual action — each flagged explicitly.

### Pages

- Single-select / multi-select toggle.
- Sort dropdown: last modified / earliest modified / title ascending-descending / filename / word count high-to-low.
- Bulk operations: add tags to many, change layout for many, delete many.
- Detail area shows full front-matter table (key / value / type) + a "Pages referencing this" section (path / permalink / shared-tag match).
- Resource recognition (CSS / JS / images) preserved.

### Localization

- Top menu "Language": Follow System / 简体中文 / English / 日本語.
- Switches immediately (Apple-native `.environment(\.locale, ...)` + forced re-render via `.id`).
- Translations managed via Xcode 15 Strings Catalog (`.xcstrings`).
- Currently covers `zh-Hans` + `en`; `ja` strings to follow in a separate PR.

### Environment Docs

- Sidebar "Environment" page: 8 built-in chapters — Node.js / nvm / Git / Hexo / Shell / Troubleshooting / Privacy.
- Each section has one-click copy-to-clipboard commands (`brew install node`, `xcode-select --install`, etc).
- BuildView shows a red banner with a jump button when Node is missing.

## Requirements

| Item | Requirement |
| --- | --- |
| OS | macOS 26 or later |
| Build from source | Xcode 26 or later (project deploy target is macOS 26.0) |
| Project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

### Dependencies: install them yourself; HexoMan ships none

HexoMan does **not** bundle Node.js, npm, git, hexo, or any embedded runtime. It calls the versions already installed on your system.

| Command | Why | How to install |
| --- | --- | --- |
| `node` / `npm` | Runs hexo; installs site deps and themes | `brew install node`, or grab the official package from [nodejs.org](https://nodejs.org) (18+ recommended; required by Hexo 8) |
| `hexo` | Only needed to create a new site | Don't install it. HexoMan uses your npm to install a copy of `hexo-cli` into its own directory — see below |
| `git` | The Git page's commit / push / pull | `xcode-select --install` (ships with Xcode) or `brew install git` |

The Build & Preview page has an **Environment Health Check** panel that reports the version and absolute path of every command, with install instructions for anything missing. "Re-check" forces a fresh read of your shell config.

### Why we read your zsh config

GUI apps launched from Dock or Finder do **not** source `~/.zshrc`, but Homebrew's PATH comes from `eval $(brew shellenv)` living in that file. Result: `node` is `/opt/homebrew/bin/node` in Terminal, but HexoMan only sees `/usr/bin:/bin` and finds nothing.

HexoMan's fix: on launch, run zsh once, source `.zshenv` → `.zprofile` → `.zshrc` in the standard order, capture the resulting environment into a cache, and inherit that into every child process. Whatever `node` resolves to in Terminal will resolve to the same thing inside HexoMan.

- rc files are located via `$ZDOTDIR` → `$HOME`, matching zsh's own rules.
- rc output and warnings are discarded so they don't pollute HexoMan's log panel.
- Common prefixes like `/opt/homebrew/bin` are prepended to PATH as a safety net when brew isn't in rc.
- One-time cost: ~2 s on first launch (your rc has starship / orbstack / brew shellenv), then 0.1–0.8 s per command.

Disable in the health-check panel if you don't want it; or fill in a custom rc path.

## Install & Run

### Option 1: Download a Release

1. Download `HexoMan-<version>-macos.zip` from [Releases](https://github.com/Mofan2020/HexoMan/releases).
2. Unzip and drag `HexoMan.app` into `/Applications`.

**First launch will be blocked by Gatekeeper — this is expected.** Releases have no Apple Developer certificate; the app is ad-hoc signed and not notarized, so macOS will not let you double-click it open. Two options:

- Right-click (or Control-click) `HexoMan.app` → "Open" → click "Open" again in the prompt.
- Or remove the quarantine attribute in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/HexoMan.app
```

After that, normal double-click launch works.

### Option 2: Build from Source

```sh
brew install xcodegen      # required for generating the project
xcodegen generate          # produces HexoMan.xcodeproj
open HexoMan.xcodeproj     # select the HexoMan scheme and run
```

Command-line build:

```sh
./scripts/build-release.sh   # output: build/release/HexoMan.app
```

## Usage Guide

### Add a Site

Open the left sidebar "Sites" → "Choose site folder…" → select your Hexo project root (the directory containing `_config.yml` and `package.json`).

After adding, HexoMan immediately probes the site: reads `title` / `url` / `theme`, finds hexo and theme versions from `package.json`, checks `node_modules`, detects whether it's a Git repo and reads the remote from `.git/config`.

### Site Dependencies

When deps are missing, the Overview and Build pages show a hint. Go to "Sites" and click "Install dependencies" — HexoMan uses your system npm to run `npm install` in the site directory. After that, hexo runs from the site's local `node_modules/.bin/hexo`, and its version matches `package.json` exactly.

### Write a Post

On the Posts page, top-left "New" → fill title (required), tags, categories → editor opens for the body → `⌘S` to save.

The file lands in the site's post directory (see "How It Works" below); the filename is the title slugified, with a numeric suffix for collisions. Delete sends the file to the Trash, not a hard delete.

### Generate & Preview

Build & Preview page → "Generate site" runs `hexo generate`; output lands in `public`. Want live preview? Click "Start preview" then "Open preview" to view it in the browser. Port changes require stopping and starting the preview.

### Edit Config

On the Config page, pick a `_config*.yml`, use the top key bar to jump, edit, then `⌘S`. Saving only writes the file back to disk — **generate does not run automatically**; you need to run it on the Build page for changes to take effect.

### Git Panel

Fill in a commit message on the Git page and click "Commit all changes". Pull uses `git pull --rebase`; Push is disabled when there's nothing to push. Conflicts show as a red banner at the top of the page listing the conflicting files — resolve them manually, then commit again.

### Keyboard Shortcuts

| Shortcut | Action | Where |
| --- | --- | --- |
| `⌘N` | Jump to Posts page (the New button is in its top-left) | Menu |
| `⇧⌘O` | Jump to Sites page | Menu |
| `⌘R` | Refresh all data for the current site | Menu |
| `⌘B` | Generate site (`hexo generate`) | Menu |
| `⇧⌘R` | Start / stop preview server | Menu |
| `⌥⌘P` | Open preview in browser | Menu |
| `⌘E` | Open the editor for the currently selected post | Post detail page |
| `⌘S` | Save (post editor, config editor) | Inside editors |

Menu items that need a site are disabled when no site is selected.

## How It Works

This section describes what HexoMan actually does on your machine, so you can judge which behaviors to trust.

### How the `hexo` executable is found

`HexoService.resolveInvocation` selects one with a fixed priority (the bottom of the sidebar shows which one is in use right now):

1. **Custom path** — the executable you typed in on the Build & Preview page.
2. **Site local deps** — `<site>/node_modules/.bin/hexo` if it exists and is executable; the most accurate, matches the site's `package.json` exactly.
3. **User PATH** — `hexo` from your shell environment (e.g. `npm i -g hexo-cli`), using the PATH discovered by the zsh bootstrap above.
4. **Common global prefixes** — `/usr/local/bin/hexo`, `/opt/homebrew/bin/hexo`, `~/.nvm/versions/node/<latest>/bin/hexo`.
5. **HexoMan self-install** — a copy HexoMan previously installed when creating a new site.
6. **npx** — fallback to `npx hexo` if all of the above miss; the UI marks this as "npx (will download on demand)".

The actual executable and arguments are printed in the "Command preview" on the Build & Preview page so you can see exactly what will run.

### How `hexo-cli` is acquired when creating a site

Only `hexo init` strictly needs `hexo-cli` first, and asking users to `npm i -g hexo-cli` is annoying. So HexoMan uses **your own npm** to install `hexo-cli` into `~/Library/Application Support/HexoMan/cli`:

1. Look for an existing copy first: custom path → your PATH `hexo` → HexoMan's previous self-install.
2. Only if none exist, run `npm install hexo-cli` into HexoMan's own directory.
3. After `hexo init` succeeds, HexoMan runs `npm install` inside the new site. From that moment hexo is the site's local dependency, and the self-installed copy never participates again.

Installing into Application Support instead of globally keeps your global `node_modules` clean: deleting HexoMan deletes its bundled copy too, and nothing is written to any shell config.

### Where posts live

Posts are Markdown files in the site's post directory. **There is no database.** The directory is read from `_config.yml`: prefer `new_dir`, then `<source_dir>/_posts`, falling back to `source/_posts`.

The `---`-wrapped front-matter at the top of each file is parsed into title, date, tags, categories, draft status. Parsing preserves the original keys and order — the goal is "read it as it is, write it back exactly as it was". Changing the title does not reformat your other hand-written fields. Dates accept both `YYYY-MM-DD HH:mm:ss` and `YYYY-MM-DD`.

Config and post read/write go straight to the filesystem. No intermediate cache, no intermediate database.

### What HexoMan does not do

No network calls, no uploading to external services, no accounts, no auto-update, no crash reporting, no cloud sync. Config lives only on your machine at `~/Library/Application Support/HexoMan/settings.json`.

## How Custom Content Is Injected

"Where do I add a banner?" is the question that trips up beginners most. The usual (wrong) answer is to edit `themes/landscape/layout/` — that's overwritten on `npm install`, and a theme upgrade silently wipes your work.

HexoMan's approach is to auto-create a pair of files in the site:

| File | Maintained by | Purpose |
| --- | --- | --- |
| `scripts/hexoman-inject.json` | You (via HexoMan's UI) | Your HTML, split into head and body |
| `scripts/hexoman-inject.js` | HexoMan | The injection logic — reads the json and inserts into every page |

Injection uses Hexo's `_after_html_render` hook, inserting before each page's `</head>` / `</body>`. Three advantages over editing theme source:

- Survives theme upgrades and `npm install`.
- Doesn't depend on whether the theme supports an inject directory — **works with any theme**.
- Deleting those two files turns the feature off completely; no leftover state in the site.

> **Implementation gotcha:** the argument to `_after_html_render` varies between Hexo versions. Hexo 8.1.2 passes a **string**; some versions pass an object `{ path, content }`. The generated script handles both forms, and **every branch guarantees a non-empty return value**. This is not paranoia: an early version written for the "object" form caused the filter to return `undefined`; the build didn't error and cheerfully reported "46 files generated", but the produced HTML was 0 bytes and the entire site was silently wiped.

## Settings Storage

`~/Library/Application Support/HexoMan/settings.json`, containing:

- `sites`: known sites (path + last-opened time)
- `lastSitePath`: the last opened site
- `serverPort`: preview port, default 4000
- `autoScrollLog`: whether the log auto-scrolls to the bottom
- `customHexoPath`: hand-typed hexo executable path; empty = auto-detect
- `usesShellEnvironment`: whether to source zsh rc files to get the real PATH; default `true`
- `customRCPath`: hand-typed zsh rc path; empty = auto-locate via `$ZDOTDIR` → `$HOME`

Settings are auto-saved when the app backgrounds or closes. Deleting this file is a factory reset — your site files are untouched.

## Development

### Layout

```
HexoMan/
├── HexoManApp.swift        App entry, menu bar, shortcuts
├── Core/                   UI-independent models and file I/O
│   ├── HexoManModel.swift  State hub — the UI talks only to it
│   ├── HexoSite.swift      Site model + site probing
│   ├── BlogPost.swift      Post model + read/write under source/_posts
│   ├── FrontMatter.swift   Front-matter parsing and re-write
│   ├── ConfigFile.swift    List and read/write _config*.yml
│   ├── SiteSettings.swift  Visual read/write for common config items (lossless; doesn't touch nested blocks)
│   ├── CustomContent.swift Config + script for head/body injection
│   ├── SnippetLibrary.swift Common code snippets (banner/stats/CSS/JS)
│   ├── GitService.swift    git status / log / commit / push / pull
│   ├── HexoService.swift   Locate hexo executable + assemble commands
│   ├── HexoCLIBootstrap.swift  Bootstrap hexo-cli with user's npm when creating a site
│   ├── ShellRunner.swift   Subprocess execution, live log, shell environment cache
│   ├── ShellEnvironment.swift   zsh bootstrap, reads .zshenv/.zprofile/.zshrc
│   ├── HexoEnvironment.swift    node/npm/npx/hexo/git toolchain health check
│   ├── YAMLScalars.swift   YAML top-level scalar parsing
│   ├── SettingsStore.swift settings.json read/write
│   └── SystemIntegration.swift Reveal-in-Finder and similar system integration
└── Views/                  UI
    ├── ContentView.swift   Sidebar + content-area dispatch
    ├── SiteManagerView / DashboardView / PostsView
    ├── PostEditorView / BuildView / ConfigView / GitView
    ├── VisualConfigView    The visual half of the config page (form + custom content)
    └── Components.swift    Reusable cards, tags, empty states, log console
```

The split is simple: **the UI never touches the filesystem.** All I/O happens in `Core/`; `Views/` only reads state from `HexoManModel` and issues actions.

### The project is generated

`HexoMan.xcodeproj` is not in the repo; `project.yml` is the single source of truth. To change project structure, edit `project.yml` and run:

```sh
xcodegen generate
```

### Adding a New Page

1. Add a case to `Core/SidebarItem` in `HexoManModel.swift`, with `title` and `symbolName`.
2. Write the matching View under `HexoMan/Views/`.
3. Add a branch in `ContentView.content`'s switch; wrap with `siteRequired { ... }` if the page needs a site.
4. `xcodegen generate` and run.

Any data the UI needs comes from `HexoManModel`. If you need new file I/O, add a new Store/Service in `Core/` and expose a method on the model.

## Roadmap

- Create a new Hexo project from inside the app
- Install site dependencies from inside the app
- Edit configs under the theme directory

## License

[MIT](LICENSE) © 2026 Mofan2020