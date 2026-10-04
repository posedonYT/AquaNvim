-- Aqua Extras — включаемые модули (языки, плагины), как LazyVim Extras.
--
-- Каждый extra — файл lua/aqua/extras/<категория>/<имя>.lua, возвращающий lazy-спеку.
-- Первая строка вида `-- desc: ...` — описание для меню.
-- Список включённых хранится в aquanvim.json в папке конфига.
--
--   :AquaExtras                    — меню (Enter / x — включить/выключить)
--   :AquaExtras enable lang.go     — включить
--   :AquaExtras disable lang.go    — выключить
--   :AquaExtras list               — список включённых
local M = {}

--- Включены по умолчанию (если aquanvim.json ещё нет) — набор прежнего AquaNvim.
M.defaults = {
  "lang.typescript",
  "lang.python",
  "lang.rust",
  "lang.prisma",
  "lang.json",
}

M.categories = {
  lang = { icon = "󰗊", title = "Языки" },
  editor = { icon = "󰏫", title = "Редактор" },
  coding = { icon = "\u{f121}", title = "Кодинг" },
  ui = { icon = "󰙵", title = "Интерфейс" },
  ai = { icon = "󰚩", title = "AI" },
  dap = { icon = "\u{f188}", title = "Отладка" },
}

function M.dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(src) .. "/extras"
end

function M.file()
  return vim.env.AQUA_EXTRAS_FILE or (vim.fn.stdpath("config") .. "/aquanvim.json")
end

---@class aqua.Extra
---@field name string  например "lang.go"
---@field category string
---@field desc string
---@field file string
---@field module string
---@field enabled boolean

--- Все доступные extras.
---@return aqua.Extra[]
function M.all()
  local enabled = {}
  for _, name in ipairs(M.enabled()) do
    enabled[name] = true
  end
  local res = {}
  local dir = M.dir()
  for category, type in vim.fs.dir(dir) do
    if type == "directory" then
      for fname, ftype in vim.fs.dir(dir .. "/" .. category) do
        if ftype == "file" and fname:match("%.lua$") then
          local base = fname:gsub("%.lua$", "")
          local file = dir .. "/" .. category .. "/" .. fname
          local first = (io.lines(file)() or "")
          local name = category .. "." .. base
          res[#res + 1] = {
            name = name,
            category = category,
            desc = first:match("^%-%-%s*desc:%s*(.*)$") or "",
            file = file,
            module = "aqua.extras." .. name,
            enabled = enabled[name] == true,
          }
        end
      end
    end
  end
  table.sort(res, function(a, b)
    if a.category ~= b.category then
      return a.category < b.category
    end
    return a.name < b.name
  end)
  return res
end

---@return { extras: string[] }
function M.read()
  local f = io.open(M.file(), "r")
  if not f then
    return { extras = vim.deepcopy(M.defaults) }
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    vim.schedule(function()
      vim.notify("aquanvim.json повреждён, используются extras по умолчанию", vim.log.levels.WARN)
    end)
    return { extras = vim.deepcopy(M.defaults) }
  end
  data.extras = data.extras or {}
  return data
end

---@param data { extras: string[] }
function M.write(data)
  table.sort(data.extras)
  -- пишем вручную с отступами, чтобы файл было удобно читать в git diff
  local items = vim.tbl_map(function(name) return "    " .. vim.json.encode(name) end, data.extras)
  local lines = { "{", '  "extras": [' }
  if #items > 0 then
    lines[#lines + 1] = table.concat(items, ",\n")
  end
  vim.list_extend(lines, { "  ],", '  "version": 1', "}", "" })
  local f = assert(io.open(M.file(), "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

---@return string[]
function M.enabled()
  return M.read().extras
end

---@param name string
function M.exists(name)
  local path = M.dir() .. "/" .. name:gsub("%.", "/", 1) .. ".lua"
  return vim.fn.filereadable(path) == 1
end

--- Lazy-спека для включённых extras.
function M.spec()
  local spec = {}
  for _, name in ipairs(M.enabled()) do
    if M.exists(name) then
      spec[#spec + 1] = { import = "aqua.extras." .. name }
    else
      vim.schedule(function()
        vim.notify("Extra «" .. name .. "» не найден — пропущен", vim.log.levels.WARN, { title = "AquaNvim" })
      end)
    end
  end
  return spec
end

--- Включить / выключить extra. Возвращает новое состояние.
---@param name string
---@param state? boolean nil — переключить
function M.set(name, state)
  if not M.exists(name) then
    error("Нет такого extra: " .. name)
  end
  local data = M.read()
  local idx = vim.tbl_contains(data.extras, name) and vim.fn.index(data.extras, name) + 1 or nil
  if state == nil then
    state = idx == nil
  end
  if state and not idx then
    table.insert(data.extras, name)
  elseif not state and idx then
    table.remove(data.extras, idx)
  end
  M.write(data)
  M.dirty = true
  return state
end

local function notify_restart()
  vim.notify(
    "Extras изменены. Перезапустите Neovim — недостающие плагины установятся автоматически.",
    vim.log.levels.INFO,
    { title = "AquaNvim · Extras" }
  )
end

--- Меню Extras.
function M.picker()
  M.dirty = false
  Snacks.picker({
    title = "󰐱 Aqua Extras",
    finder = function()
      local items = {}
      for i, extra in ipairs(M.all()) do
        items[#items + 1] = vim.tbl_extend("force", extra, {
          idx = i,
          text = extra.name .. " " .. extra.desc,
          preview = { text = table.concat(vim.fn.readfile(extra.file), "\n"), ft = "lua" },
        })
      end
      return items
    end,
    preview = "preview",
    format = function(item)
      local cat = M.categories[item.category] or { icon = "\u{f15b}" }
      return {
        { item.enabled and "● " or "○ ", item.enabled and "DiagnosticOk" or "Comment" },
        { cat.icon .. " ", "Special" },
        { ("%-22s"):format(item.name), item.enabled and "Title" or "Normal" },
        { item.desc, "Comment" },
      }
    end,
    layout = { preset = "default" },
    confirm = function(picker, item)
      if not item then
        return
      end
      M.set(item.name)
      picker:refresh()
    end,
    actions = {
      toggle_extra = function(picker, item)
        if item then
          M.set(item.name)
          picker:refresh()
        end
      end,
    },
    win = {
      input = { keys = { ["x"] = { "toggle_extra", mode = { "n" } } } },
      list = { keys = { ["x"] = "toggle_extra" } },
    },
    on_close = function()
      if M.dirty then
        vim.schedule(notify_restart)
      end
    end,
  })
end

function M.create_command()
  vim.api.nvim_create_user_command("AquaExtras", function(cmd)
    local action, name = cmd.fargs[1], cmd.fargs[2]
    if not action then
      return M.picker()
    end
    if action == "list" then
      return vim.notify(table.concat(M.enabled(), "\n"), vim.log.levels.INFO, { title = "Включённые extras" })
    end
    if (action == "enable" or action == "disable" or action == "toggle") and name then
      local ok, err = pcall(M.set, name, ({ enable = true, disable = false })[action])
      if not ok then
        return vim.notify(tostring(err), vim.log.levels.ERROR, { title = "AquaNvim · Extras" })
      end
      return notify_restart()
    end
    vim.notify("Использование: :AquaExtras [list|enable <name>|disable <name>|toggle <name>]", vim.log.levels.WARN)
  end, {
    nargs = "*",
    desc = "Aqua Extras",
    complete = function(_, line)
      local args = vim.split(line, "%s+")
      if #args <= 2 then
        return { "list", "enable", "disable", "toggle" }
      end
      return vim.tbl_map(function(e) return e.name end, M.all())
    end,
  })
end

return M
