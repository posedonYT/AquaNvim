# 🌊 AquaNvim

```
┏━┓┏━┓╻ ╻┏━┓┏┓╻╻ ╻╻┏┳┓
┣━┫┃┓┃┃ ┃┣━┫┃┗┫┃┏┛┃┃┃┃      dive deep · code clear
╹ ╹┗┻┛┗━┛╹ ╹╹ ╹┗┛ ╹╹ ╹
```

Дистрибутив Neovim в водной тематике с собственной цветовой палитрой **Aqua**,
включаемыми **Extras** (языки и плагины, как в LazyVim Extras), **сессиями** для каждого проекта
и встроенной интеграцией с **Claude CLI**.

Требуется **Neovim ≥ 0.11**, `git`, [Nerd Font](https://www.nerdfonts.com/), `ripgrep`;
опционально: `lazygit`, `fd`, [`claude`](https://docs.anthropic.com/en/docs/claude-code).

## Установка

### ❓ Сделайте резервную копию текущего конфига (если он есть)

```bash
mv ~/.config/nvim ~/.config/nvim.bak
mv ~/.local/share/nvim ~/.local/share/nvim.bak
mv ~/.local/state/nvim ~/.local/state/nvim.bak
mv ~/.cache/nvim ~/.cache/nvim.bak
```

### ✅ Клонирование

```bash
git clone --depth 1 https://github.com/posedonYT/AquaNvim.git ~/.config/nvim
nvim
```

Плагины, LSP-серверы и парсеры treesitter устанавливаются сами при первом запуске.

### 🧪 Попробовать, не трогая свой конфиг

```bash
git clone https://github.com/posedonYT/AquaNvim.git ~/.config/aquanvim
NVIM_APPNAME=aquanvim nvim
```

## 🗂 Структура

```
init.lua                    точка входа
aquanvim.json               включённые extras (редактируется через :AquaExtras)
colors/aqua.lua             :colorscheme aqua
lua/aqua/                   сам дистрибутив
  config/                   опции, привязки клавиш, автокоманды
  plugins/                  основные плагины
  extras/<category>/*.lua   необязательные модули
  claude.lua                интеграция с Claude CLI
  session.lua               сессии
lua/custom/plugins/         ← ВАШИ плагины, подхватываются автоматически
```

## 🧩 Extras

`Space X` (или `:AquaExtras`) открывает меню: `Enter` / `x` включает или выключает extra, затем
перезапустите Neovim — недостающие плагины установятся автоматически.

| Категория | Extras |
|---|---|
| lang | typescript · python · rust · go · c · bash · json · yaml · markdown · prisma · docker · tailwind · web (html/css) · sql (DBUI) |
| editor | harpoon · oil · multicursor |
| coding | surround · yanky |
| ui | noice · transparent · smear-cursor · colorizer |
| ai | claudecode (мост IDE: правки Claude показываются в Neovim как диффы) |
| dap | core (отладчик) |

Включены по умолчанию: `lang.typescript`, `lang.python`, `lang.rust`, `lang.prisma`, `lang.json`.

Из командной строки: `:AquaExtras enable lang.go`, `:AquaExtras disable lang.go`, `:AquaExtras list`.

**Собственные плагины** кладите в `lua/custom/plugins/*.lua` как обычные
[спецификации lazy.nvim](https://lazy.folke.io/spec). Пример смотрите в `example.lua` в этой папке.

## 🤖 Claude CLI

| Клавиши | Действие |
|---|---|
| `Space c` | Открыть/скрыть Claude справа, в **корне проекта** текущего файла |
| `Space a C` | То же, но в **папке текущего файла** |
| `Ctrl ,` | Скрыть/показать Claude (работает и внутри окна Claude) |
| `Space a f` | Добавить текущий файл в промпт (`@path`) |
| `Space a s` | (visual) Отправить выделение с путём и номерами строк |
| `Space a d` | Отправить диагностику текущей строки |
| `Space a c` / `Space a r` | `claude --continue` / `claude --resume` |
| `Space a p` | Выбрать запущенный экземпляр Claude |
| `Space a k` | Завершить Claude для этого проекта |

* У каждого проекта **свой экземпляр Claude**. Скрытие окна не останавливает процесс.
* Если курсор находится в Explorer или терминале, директория берётся из последнего редактируемого файла.
* Корень проекта = корень git → корень LSP → маркеры (`package.json`, `Cargo.toml`, `go.mod`, …) → папка файла.
* Файлы, изменённые Claude, перезагружаются автоматически.
* Включите extra `ai.claudecode`, и Claude подключится к Neovim как к IDE: предлагаемые правки открываются как диффы (`Space a y` — принять, `Space a n` — отклонить).
* Настройки: `vim.g.aqua_claude_cmd` (команда, например `{ "claude", "--model", "opus" }`), `vim.g.aqua_claude_width` (по умолчанию `0.4`).

## 💾 Сессии

Сессия автоматически сохраняется при выходе — по одной на **директорию + git-ветку**.
Explorer, Claude, терминалы и дашборд в неё не сохраняются, поэтому пустые «мёртвые» окна
не возвращаются. При смене проекта (`:cd`, `Space f p`) сначала сохраняется сессия предыдущего проекта.

| Клавиши | Действие |
|---|---|
| `Space q s` | Восстановить сессию для текущей директории |
| `Space q l` | Восстановить последнюю сессию |
| `Space q S` | Выбрать сессию |
| `Space q w` | Сохранить сейчас |
| `Space q d` | Не сохранять эту сессию при выходе |
| `Space q a` | Включить/выключить автовосстановление при запуске `nvim` без аргументов |

## ⌨️ Горячие клавиши

Нажмите `Space` и подождите: меню покажет все действия.

| Клавиши | Действие |
|---|---|
| `Space e` / `Space E` | Explorer (корень проекта / cwd) |
| `Space Space` | Поиск файлов |
| `Space /` | Grep по проекту |
| `Space ,` | Буферы |
| `Space f r` | Недавние файлы |
| `Space f p` | Проекты |
| `Space g g` | Lazygit |
| `Space l a` / `Space l r` / `Space l f` | Code action / переименование / форматирование |
| `Space b d` | Закрыть буфер |
| `Shift h` / `Shift l` | Предыдущий / следующий буфер |
| `Space - ` / `Space \|` | Разделить вниз / вправо |
| `Space u …` | Переключатели: перенос строк, диагностика, inlay hints, прозрачность, автоформат… |
| `Space n` | Новый файл |
| `Ctrl s` | Сохранить |
| `Ctrl a` | Выделить всё |
| `/` (visual) | Закомментировать / раскомментировать выделение |
| `Ctrl /` | Терминал |
| `s` | Flash-прыжок |

## 🎨 Тема

Палитра находится в `lua/aqua/theme/palette.lua`: abyss, deep, reef, turquoise, lagoon,
foam, coral, sand. Прозрачный фон: extra `ui.transparent` или `Space u B`.

## 🧪 Тесты

```bash
make test   # headless-тесты в изолированном окружении (.tests/)
make run    # запустить AquaNvim в том же изолированном окружении
```
