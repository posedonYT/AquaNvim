# 🌊 AquaNvim

```
┏━┓┏━┓╻ ╻┏━┓┏┓╻╻ ╻╻┏┳┓
┣━┫┃┓┃┃ ┃┣━┫┃┗┫┃┏┛┃┃┃┃      dive deep · code clear
╹ ╹┗┻┛┗━┛╹ ╹╹ ╹┗┛ ╹╹ ╹
```

A water‑themed Neovim distribution with its own **Aqua** colour palette, toggleable
**Extras** (languages and plugins, like LazyVim Extras), per‑project **sessions**, and
built‑in **Claude CLI** integration.

Requires **Neovim ≥ 0.11**, `git`, a [Nerd Font](https://www.nerdfonts.com/), `ripgrep`;
optional: `lazygit`, `fd`, [`claude`](https://docs.anthropic.com/en/docs/claude-code).

## Install

### ❓ Back up your current config (if any)

```bash
mv ~/.config/nvim ~/.config/nvim.bak
mv ~/.local/share/nvim ~/.local/share/nvim.bak
mv ~/.local/state/nvim ~/.local/state/nvim.bak
mv ~/.cache/nvim ~/.cache/nvim.bak
```

### ✅ Clone

```bash
git clone --depth 1 https://github.com/posedonYT/AquaNvim.git ~/.config/nvim
nvim
```

Plugins, LSP servers and treesitter parsers install themselves on first launch.

### 🧪 Try it without touching your config

```bash
git clone https://github.com/posedonYT/AquaNvim.git ~/.config/aquanvim
NVIM_APPNAME=aquanvim nvim
```

## 🗂 Layout

```
init.lua                    entry point
aquanvim.json               enabled extras (edited via :AquaExtras)
colors/aqua.lua             :colorscheme aqua
lua/aqua/                   the distribution itself
  config/                   options, keymaps, autocmds
  plugins/                  core plugins
  extras/<category>/*.lua   optional modules
  claude.lua                Claude CLI integration
  session.lua               sessions
lua/custom/plugins/         ← YOUR plugins, picked up automatically
```

## 🧩 Extras

`Space X` (or `:AquaExtras`) opens the menu: `Enter` / `x` toggles an extra, then restart
Neovim and missing plugins install automatically.

| Category | Extras |
|---|---|
| lang | typescript · python · rust · go · c · bash · json · yaml · markdown · prisma · docker · tailwind · web (html/css) · sql (DBUI) |
| editor | harpoon · oil · multicursor |
| coding | surround · yanky |
| ui | noice · transparent · smear-cursor · colorizer |
| ai | claudecode (IDE bridge: Claude edits shown as diffs in Neovim) |
| dap | core (debugger) |

On by default: `lang.typescript`, `lang.python`, `lang.rust`, `lang.prisma`, `lang.json`.

From the command line: `:AquaExtras enable lang.go`, `:AquaExtras disable lang.go`, `:AquaExtras list`.

**Your own plugins** go in `lua/custom/plugins/*.lua` as ordinary
[lazy.nvim specs](https://lazy.folke.io/spec). See `example.lua` there.

## 🤖 Claude CLI

| Key | Action |
|---|---|
| `Space c` | Open/hide Claude on the right, in the **project root** of the current file |
| `Space a C` | Same, but in the **current file's directory** |
| `Ctrl ,` | Hide/show Claude (also works inside the Claude window) |
| `Space a f` | Add the current file to the prompt (`@path`) |
| `Space a s` | (visual) Send the selection with path and line numbers |
| `Space a d` | Send the diagnostics for the current line |
| `Space a c` / `Space a r` | `claude --continue` / `claude --resume` |
| `Space a p` | Pick a running Claude instance |
| `Space a k` | Kill Claude for this project |

* Each project gets **its own Claude instance**. Hiding the window keeps the process running.
* If the cursor is in the Explorer or a terminal, the directory comes from the last file you edited.
* Project root = git root → LSP root → markers (`package.json`, `Cargo.toml`, `go.mod`, …) → file's folder.
* Files Claude changes are reloaded automatically.
* Enable the `ai.claudecode` extra and Claude connects to Neovim as an IDE: proposed edits open as diffs (`Space a y` accept, `Space a n` reject).
* Settings: `vim.g.aqua_claude_cmd` (command, e.g. `{ "claude", "--model", "opus" }`), `vim.g.aqua_claude_width` (default `0.4`).

## 💾 Sessions

The session saves automatically on exit, one per **directory + git branch**.
The Explorer, Claude, terminals and the dashboard are not saved into it, so you never get
empty "dead" windows back. Switching projects (`:cd`, `Space f p`) saves the previous project's session first.

| Key | Action |
|---|---|
| `Space q s` | Restore the session for the current directory |
| `Space q l` | Restore the last session |
| `Space q S` | Pick a session |
| `Space q w` | Save now |
| `Space q d` | Don't save this session on exit |
| `Space q a` | Toggle auto‑restore when starting `nvim` with no arguments |

## ⌨️ Hotkeys

Press `Space` and wait: the menu shows every action.

| Key | Action |
|---|---|
| `Space e` / `Space E` | Explorer (project root / cwd) |
| `Space Space` | Find files |
| `Space /` | Grep the project |
| `Space ,` | Buffers |
| `Space f r` | Recent files |
| `Space f p` | Projects |
| `Space g g` | Lazygit |
| `Space l a` / `Space l r` / `Space l f` | Code action / rename / format |
| `Space b d` | Close buffer |
| `Shift h` / `Shift l` | Previous / next buffer |
| `Space - ` / `Space \|` | Split below / right |
| `Space u …` | Toggles: wrap, diagnostics, inlay hints, transparency, autoformat… |
| `Space n` | New file |
| `Ctrl s` | Save |
| `Ctrl a` | Select all |
| `/` (visual) | Comment / uncomment the selection |
| `Ctrl /` | Terminal |
| `s` | Flash jump |

## 🎨 Theme

The palette lives in `lua/aqua/theme/palette.lua`: abyss, deep, reef, turquoise, lagoon,
foam, coral, sand. Transparent background: the `ui.transparent` extra or `Space u B`.

## 🧪 Tests

```bash
make test   # headless tests in an isolated environment (.tests/)
make run    # run AquaNvim in the same isolated environment
```
