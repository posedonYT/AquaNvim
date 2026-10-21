-- Определение стека проекта: языки и их версии (требуемые и установленные), зависимости
-- с точными версиями из lock-файлов, предупреждения о несоответствиях.
--
--   local stack = require("aqua.ai.stack")
--   local st = stack.detect(root)       -- кэшируется, пока не изменились манифесты
--   stack.summary(st, 1500)             -- коротко, для системного промпта
--   stack.report(st)                    -- подробно, для инструмента project_stack
--   stack.targets(st)                   -- что изучать: { {lang="go", version="1.27", label="Go 1.27"}, ... }
local uv = vim.uv or vim.loop
local cut = require("aqua.util.text").cut

local M = {}

---@class aqua.stack.Ctx
---@field root string
---@field files table<string, string[]> имя манифеста → абсолютные пути (ближайшие к корню — первыми)
---@field sources integer число исходников C/C++
---@field read fun(path: string): string?
---@field rel fun(path: string): string

M.PARSERS = { "go", "js", "python", "rust", "cpp" }

M.MANIFESTS = {
  "go.mod", "go.work",
  "package.json",
  "pyproject.toml", "requirements.txt", "setup.py", ".python-version",
  "Cargo.toml",
  "CMakeLists.txt", "compile_commands.json", "meson.build", "Makefile", "vcpkg.json", "conanfile.txt",
}
local MANIFEST_SET = {}
for _, m in ipairs(M.MANIFESTS) do MANIFEST_SET[m] = true end

M.IGNORE = {
  [".git"] = true, node_modules = true, vendor = true, target = true, dist = true, [".venv"] = true, venv = true,
  __pycache__ = true, [".tests"] = true, [".cache"] = true, [".idea"] = true, [".vscode"] = true,
}
local CPP_EXT = { c = true, cc = true, cpp = true, cxx = true, h = true, hh = true, hpp = true, hxx = true, ixx = true, cppm = true }

M.max_depth = 2

--- Обход проекта (до 2 уровней) в поиске манифестов.
---@return table<string, string[]> files, integer sources
function M.scan(root)
  local files, sources = {}, 0
  local function walk(dir, depth)
    local entries = {}
    for name, t in vim.fs.dir(dir) do
      entries[#entries + 1] = { name, t }
    end
    table.sort(entries, function(a, b) return a[1] < b[1] end)
    local subdirs = {}
    for _, e in ipairs(entries) do
      local name, t = e[1], e[2]
      if t == "file" or t == "link" then
        if MANIFEST_SET[name] then
          files[name] = files[name] or {}
          table.insert(files[name], dir .. "/" .. name)
        end
        local ext = name:match("%.([%w]+)$")
        if ext and CPP_EXT[ext] then sources = sources + 1 end
      elseif t == "directory" and not M.IGNORE[name] and name:sub(1, 1) ~= "." then
        subdirs[#subdirs + 1] = dir .. "/" .. name
      end
    end
    if depth < M.max_depth then
      for _, d in ipairs(subdirs) do walk(d, depth + 1) end
    end
  end
  walk(root, 0)
  return files, sources
end

local function read(path)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > 8 * 1024 * 1024 then
    return nil
  end
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- Отпечаток: какие манифесты (и соседние lock-файлы) есть и когда менялись + $PATH.
local LOCKS = { "go.sum", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "uv.lock", "poetry.lock", "Cargo.lock",
  "rust-toolchain.toml", "rust-toolchain", ".nvmrc", ".node-version", "tsconfig.json" }
local function fingerprint(files, sources)
  local parts = { vim.env.PATH or "", tostring(sources) }
  local seen = {}
  local function add(p)
    if seen[p] then return end
    seen[p] = true
    local st = uv.fs_stat(p)
    if st then parts[#parts + 1] = ("%s:%d:%d"):format(p, st.mtime.sec, st.size) end
  end
  local names = vim.tbl_keys(files)
  table.sort(names)
  for _, name in ipairs(names) do
    for _, p in ipairs(files[name]) do
      add(p)
      local dir = vim.fs.dirname(p)
      for _, l in ipairs(LOCKS) do add(dir .. "/" .. l) end
    end
  end
  return table.concat(parts, "|")
end

---@type table<string, table>
M.cache = {}

---@class aqua.Stack
---@field root string
---@field fingerprint string
---@field ecosystems table[]

--- Определить стек проекта.
---@param root string
---@return aqua.Stack
function M.detect(root)
  local files, sources = M.scan(root)
  local fp = fingerprint(files, sources)
  local hit = M.cache[root]
  if hit and hit.fingerprint == fp then
    return hit
  end
  ---@type aqua.stack.Ctx
  local ctx = {
    root = root,
    files = files,
    sources = sources,
    read = read,
    rel = function(p) return p:sub(1, #root + 1) == root .. "/" and p:sub(#root + 2) or p end,
  }
  local st = { root = root, fingerprint = fp, ecosystems = {} }
  for _, id in ipairs(M.PARSERS) do
    local ok, eco = pcall(function() return require("aqua.ai.stack." .. id).detect(ctx) end)
    if ok and eco then
      table.insert(st.ecosystems, eco)
    elseif not ok then
      table.insert(st.ecosystems, { id = id, name = id, deps = {}, targets = {}, manifests = {}, warnings = { "ошибка разбора: " .. tostring(eco) } })
    end
  end
  M.cache[root] = st
  return st
end

--- Все цели для изучения (без повторов).
---@param st aqua.Stack
function M.targets(st)
  local res, seen = {}, {}
  for _, eco in ipairs(st.ecosystems) do
    for _, t in ipairs(eco.targets or {}) do
      local key = t.lang .. "@" .. t.version
      if not seen[key] then
        seen[key] = true
        res[#res + 1] = t
      end
    end
  end
  return res
end

--- Найти зависимость по имени во всех экосистемах.
---@return table? dep, table? eco
function M.find_dep(st, name)
  local lname = name:lower()
  for _, eco in ipairs(st.ecosystems) do
    for _, d in ipairs(eco.deps or {}) do
      if d.name:lower() == lname then
        return d, eco
      end
    end
  end
end

---@param eco table
local function headline(eco)
  local parts = {}
  if eco.id == "go" then
    parts[#parts + 1] = ("Go %s"):format(eco.language_version or "?")
    local d = {}
    if eco.declared then d[#d + 1] = "go.mod: go " .. eco.declared end
    if eco.toolchain then d[#d + 1] = "toolchain " .. eco.toolchain end
    d[#d + 1] = "installed: " .. (eco.installed and ("go" .. eco.installed) or "not found")
    parts[#parts + 1] = "(" .. table.concat(d, "; ") .. ")"
    if eco.module then parts[#parts + 1] = "module " .. eco.module end
  elseif eco.id == "js" then
    parts[#parts + 1] = ("Node.js %s"):format(eco.language_version or "?")
    local d = { "installed: " .. (eco.installed and ("v" .. eco.installed) or "not found") }
    if eco.declared then d[#d + 1] = "required: " .. eco.declared end
    if eco.lockfile then d[#d + 1] = "lock: " .. eco.lockfile end
    parts[#parts + 1] = "(" .. table.concat(d, "; ") .. ")"
    if eco.typescript then
      parts[#parts + 1] = "+ TypeScript " .. eco.typescript .. (eco.ts_target and (" (target " .. eco.ts_target .. ")") or "")
    end
  elseif eco.id == "python" then
    parts[#parts + 1] = ("Python %s"):format(eco.language_version or "?")
    local d = { "installed: " .. (eco.installed or "not found") }
    if eco.declared then d[#d + 1] = "required: " .. eco.declared end
    if eco.lockfile then d[#d + 1] = "lock: " .. eco.lockfile end
    parts[#parts + 1] = "(" .. table.concat(d, "; ") .. ")"
  elseif eco.id == "rust" then
    parts[#parts + 1] = ("Rust %s"):format(eco.language_version or "?")
    local d = { "installed: rustc " .. (eco.installed or "not found") }
    if eco.edition then d[#d + 1] = "edition " .. eco.edition end
    if eco.declared then d[#d + 1] = "rust-version/toolchain " .. eco.declared end
    parts[#parts + 1] = "(" .. table.concat(d, "; ") .. ")"
  elseif eco.id == "cpp" then
    local stds = {}
    if eco.cxx_std then stds[#stds + 1] = "C++" .. eco.cxx_std end
    if eco.c_std then stds[#stds + 1] = "C" .. eco.c_std end
    parts[#parts + 1] = #stds > 0 and table.concat(stds, " + ") or "C/C++ (standard not set)"
    parts[#parts + 1] = "(compiler: " .. (eco.compiler or "not found") .. ")"
  else
    parts[#parts + 1] = eco.name
  end
  return table.concat(parts, " ")
end
M.headline = headline

local function dep_str(d)
  return d.name .. (d.version and (" " .. d.version) or "") .. (d.dev and " (dev)" or "") .. (d.replaced and (" => " .. d.replaced) or "")
end

--- Краткая сводка (для системного промпта), не длиннее max символов.
---@param st aqua.Stack
---@param max? integer
function M.summary(st, max)
  max = max or 1500
  if #st.ecosystems == 0 then
    return "No known project manifests found (go.mod, package.json, pyproject.toml, Cargo.toml, CMakeLists.txt...)."
  end
  local per = math.floor(max / #st.ecosystems)
  local out = {}
  for _, eco in ipairs(st.ecosystems) do
    local lines = { "- " .. headline(eco) }
    for _, w in ipairs(eco.warnings or {}) do
      lines[#lines + 1] = "  ! " .. w
    end
    local deps = vim.tbl_filter(function(d) return not d.dev end, eco.deps or {})
    if #deps > 0 then
      local prefix = ("  deps (%d direct%s): "):format(#deps, (eco.indirect_count or 0) > 0 and (", " .. eco.indirect_count .. " indirect") or "")
      local used = #table.concat(lines, "\n") + #prefix
      local items = {}
      for i, d in ipairs(deps) do
        local s = dep_str(d)
        if used + #s + 2 > per - 20 then
          items[#items + 1] = ("… +%d more (see project_stack)"):format(#deps - i + 1)
          break
        end
        items[#items + 1] = s
        used = used + #s + 2
      end
      lines[#lines + 1] = prefix .. table.concat(items, ", ")
    end
    local text = table.concat(lines, "\n")
    if #text > per then text = cut(text, per - 3) .. "…" end
    out[#out + 1] = text
  end
  local res = table.concat(out, "\n")
  return #res > max and (cut(res, max - 3) .. "…") or res
end

--- Полный отчёт для инструмента project_stack.
---@param st aqua.Stack
function M.report(st)
  if #st.ecosystems == 0 then
    return M.summary(st)
  end
  local out = {}
  for _, eco in ipairs(st.ecosystems) do
    out[#out + 1] = "## " .. headline(eco)
    out[#out + 1] = "manifests: " .. table.concat(eco.manifests or {}, ", ")
    for _, w in ipairs(eco.warnings or {}) do out[#out + 1] = "warning: " .. w end
    if #(eco.targets or {}) > 0 then
      out[#out + 1] = "knowledge targets: " .. table.concat(vim.tbl_map(function(t) return t.label end, eco.targets), ", ")
    end
    if #(eco.deps or {}) > 0 then
      out[#out + 1] = ("dependencies (%d direct%s):"):format(#eco.deps, (eco.indirect_count or 0) > 0 and (", " .. eco.indirect_count .. " indirect") or "")
      for _, d in ipairs(eco.deps) do out[#out + 1] = "  - " .. dep_str(d) end
    end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

return M
