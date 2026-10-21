-- Go: go.mod, go.sum, go.work + установленный тулчейн.
local version = require("aqua.ai.stack.version")
local probe = require("aqua.ai.stack.probe")

local M = {}

local function unquote(s)
  return (s:gsub('^"(.*)"$', "%1"):gsub("^`(.*)`$", "%1"))
end

--- Разбор go.mod.
---@param text string
function M.parse_gomod(text)
  local mod = { requires = {}, replaces = {}, excludes = {}, retracts = {} }
  local block -- текущий блок: "require" | "replace" | "exclude" | "retract"
  for raw in (text or ""):gmatch("[^\n]*") do
    local comment = raw:match("//(.*)$") or ""
    local line = vim.trim((raw:gsub("//.*$", "")))
    local indirect = comment:match("^%s*indirect") ~= nil
    if block then
      if line == ")" then
        block = nil
      elseif line ~= "" then
        M._entry(mod, block, line, indirect)
      end
    elseif line ~= "" then
      local kw, rest = line:match("^(%a+)%s*(.*)$")
      if kw == "module" then
        mod.module = unquote(vim.trim(rest))
      elseif kw == "go" then
        mod.go = vim.trim(rest)
      elseif kw == "toolchain" then
        mod.toolchain = vim.trim(rest)
      elseif kw == "require" or kw == "replace" or kw == "exclude" or kw == "retract" then
        if rest == "(" then
          block = kw
        else
          M._entry(mod, kw, rest, indirect)
        end
      end
    end
  end
  return mod
end

function M._entry(mod, kind, line, indirect)
  if kind == "require" then
    local path, ver = line:match("^(%S+)%s+(%S+)")
    if path then
      table.insert(mod.requires, { name = unquote(path), version = ver, direct = not indirect })
    end
  elseif kind == "replace" then
    local from, to = line:match("^(.-)%s*=>%s*(.+)$")
    if from then
      local fpath, fver = from:match("^(%S+)%s*(%S*)$")
      local tpath, tver = to:match("^(%S+)%s*(%S*)$")
      table.insert(mod.replaces, { from = fpath, from_version = fver ~= "" and fver or nil, to = tpath, version = tver ~= "" and tver or nil })
    end
  elseif kind == "exclude" then
    local path, ver = line:match("^(%S+)%s+(%S+)")
    if path then table.insert(mod.excludes, { name = path, version = ver }) end
  elseif kind == "retract" then
    table.insert(mod.retracts, line)
  end
end

--- Разбор go.sum: { [module] = { [version] = true } } (строки "/go.mod" тоже учитываются).
function M.parse_gosum(text)
  local sum, count = {}, 0
  for line in (text or ""):gmatch("[^\n]+") do
    local path, ver = line:match("^(%S+)%s+(%S+)%s+h1:")
    if path then
      ver = ver:gsub("/go%.mod$", "")
      sum[path] = sum[path] or {}
      if not sum[path][ver] then count = count + 1 end
      sum[path][ver] = true
    end
  end
  return sum, count
end

--- Разбор go.work: версия go и use-директории.
function M.parse_gowork(text)
  local work, in_use = { use = {} }, false
  for raw in (text or ""):gmatch("[^\n]*") do
    local line = vim.trim((raw:gsub("//.*$", "")))
    if in_use then
      if line == ")" then in_use = false elseif line ~= "" then table.insert(work.use, line) end
    elseif line:match("^go%s") then
      work.go = vim.trim(line:sub(3))
    elseif line == "use (" then
      in_use = true
    elseif line:match("^use%s") then
      table.insert(work.use, vim.trim(line:sub(4)))
    end
  end
  return work
end

---@param ctx aqua.stack.Ctx
function M.detect(ctx)
  local gomod = ctx.files["go.mod"] and ctx.files["go.mod"][1]
  local gowork = ctx.files["go.work"] and ctx.files["go.work"][1]
  if not gomod and not gowork then
    return nil
  end
  local mod = gomod and M.parse_gomod(ctx.read(gomod) or "") or { requires = {}, replaces = {} }
  local work = gowork and M.parse_gowork(ctx.read(gowork) or "") or nil
  local declared = mod.go or (work and work.go)
  local installed = probe.version("go")

  local eco = {
    id = "go",
    name = "Go",
    declared = declared,
    toolchain = mod.toolchain,
    installed = installed,
    module = mod.module,
    manifests = {},
    deps = {},
    indirect_count = 0,
    warnings = {},
    targets = {},
    dir = gomod and vim.fs.dirname(gomod) or vim.fs.dirname(gowork),
  }
  for _, p in ipairs({ gomod, gowork }) do
    if p then table.insert(eco.manifests, ctx.rel(p)) end
  end

  -- go.sum рядом с go.mod
  local gosum_path = gomod and (vim.fs.dirname(gomod) .. "/go.sum")
  local gosum = gosum_path and ctx.read(gosum_path)
  local sum = gosum and M.parse_gosum(gosum) or nil
  if gosum then table.insert(eco.manifests, ctx.rel(gosum_path)) end

  local replaced = {}
  for _, r in ipairs(mod.replaces or {}) do
    replaced[r.from] = r
  end
  for _, req in ipairs(mod.requires) do
    if req.direct then
      local dep = { name = req.name, version = req.version, direct = true }
      if replaced[req.name] then
        dep.replaced = replaced[req.name].to .. (replaced[req.name].version and (" " .. replaced[req.name].version) or "")
      end
      table.insert(eco.deps, dep)
      if sum and not (sum[req.name] and sum[req.name][req.version]) and not replaced[req.name] then
        table.insert(eco.warnings, ("нет записи в go.sum: %s %s (выполните go mod tidy)"):format(req.name, req.version))
      end
    else
      eco.indirect_count = eco.indirect_count + 1
    end
  end
  if #mod.requires > 0 and gomod and not gosum then
    table.insert(eco.warnings, "нет go.sum рядом с go.mod (выполните go mod tidy)")
  end

  if not installed then
    table.insert(eco.warnings, "Go не найден в PATH — проверить код компилятором не получится")
  elseif declared and version.compare(installed, declared) < 0 then
    table.insert(eco.warnings, ("установлен Go %s, а go.mod требует go %s"):format(installed, declared))
  end
  if installed and mod.toolchain then
    local tc = mod.toolchain:gsub("^go", "")
    if version.compare(installed, tc) < 0 then
      table.insert(eco.warnings, ("toolchain в go.mod: %s, установлен go%s (с GOTOOLCHAIN=local сборка упадёт)"):format(mod.toolchain, installed))
    end
  end

  -- Знания: по версии языка из go.mod (что разрешено использовать), иначе по установленной
  local target = version.major_minor(declared or installed)
  if target then
    table.insert(eco.targets, { lang = "go", version = target, label = "Go " .. target })
  end
  eco.language_version = target
  return eco
end

return M
