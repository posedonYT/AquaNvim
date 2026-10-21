-- Python: pyproject.toml, requirements*.txt, uv.lock / poetry.lock, .python-version, установленный python3.
local version = require("aqua.ai.stack.version")
local probe = require("aqua.ai.stack.probe")
local toml = require("aqua.ai.stack.toml")

local M = {}

--- "fastapi[all]>=0.115,<1" → name, spec
function M.parse_requirement(s)
  s = vim.trim((s or ""):gsub("#.*$", ""))
  if s == "" or s:sub(1, 1) == "-" then return nil end
  s = s:gsub(";.*$", "") -- маркеры окружения
  local name, rest = s:match("^([%w][%w%._%-]*)%s*(.*)$")
  if not name then return nil end
  rest = rest:gsub("^%b[]", "")
  return name:lower():gsub("_", "-"), vim.trim(rest)
end

function M.parse_requirements(text)
  local res = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local name, spec = M.parse_requirement(line)
    if name then table.insert(res, { name = name, spec = spec }) end
  end
  return res
end

--- uv.lock / poetry.lock: { [name] = version }
function M.parse_lock(text)
  local res = {}
  local data = toml.parse(text or "")
  for _, p in ipairs(data.package or {}) do
    if type(p) == "table" and p.name and p.version then
      res[tostring(p.name):lower():gsub("_", "-")] = tostring(p.version)
    end
  end
  return res
end

---@param ctx aqua.stack.Ctx
function M.detect(ctx)
  local pyproject = ctx.files["pyproject.toml"] and ctx.files["pyproject.toml"][1]
  local reqs = ctx.files["requirements.txt"] and ctx.files["requirements.txt"][1]
  local setup = ctx.files["setup.py"] and ctx.files["setup.py"][1]
  local pyver_file = ctx.files[".python-version"] and ctx.files[".python-version"][1]
  if not (pyproject or reqs or setup) then return nil end
  local dir = vim.fs.dirname(pyproject or reqs or setup)
  local eco = { id = "python", name = "Python", manifests = {}, deps = {}, warnings = {}, targets = {}, dir = dir, indirect_count = 0 }

  local requirements, requires_python = {}, nil
  if pyproject then
    table.insert(eco.manifests, ctx.rel(pyproject))
    local data = toml.parse(ctx.read(pyproject) or "")
    local project = data.project or {}
    requires_python = project["requires-python"]
    for _, r in ipairs(type(project.dependencies) == "table" and project.dependencies or {}) do
      local name, spec = M.parse_requirement(r)
      if name then table.insert(requirements, { name = name, spec = spec }) end
    end
    local poetry = data.tool and data.tool.poetry and data.tool.poetry.dependencies
    for name, spec in pairs(type(poetry) == "table" and poetry or {}) do
      if name == "python" then
        requires_python = requires_python or (type(spec) == "string" and spec or nil)
      else
        table.insert(requirements, { name = name:lower(), spec = type(spec) == "table" and spec.version or spec })
      end
    end
  end
  if reqs then
    table.insert(eco.manifests, ctx.rel(reqs))
    vim.list_extend(requirements, M.parse_requirements(ctx.read(reqs)))
  end

  local resolved = {}
  for _, lock in ipairs({ "uv.lock", "poetry.lock" }) do
    local text = ctx.read(dir .. "/" .. lock)
    if text then
      resolved = M.parse_lock(text)
      eco.lockfile = lock
      table.insert(eco.manifests, ctx.rel(dir .. "/" .. lock))
      break
    end
  end
  local seen = {}
  for _, r in ipairs(requirements) do
    if not seen[r.name] then
      seen[r.name] = true
      local exact = r.spec and r.spec:match("^==%s*([%w%.%-]+)$")
      table.insert(eco.deps, { name = r.name, version = resolved[r.name] or exact or (r.spec ~= "" and r.spec or "*"), direct = true })
    end
  end

  local pinned = pyver_file and vim.trim((ctx.read(pyver_file) or ""):match("[^\n]*"))
  if pyver_file then table.insert(eco.manifests, ctx.rel(pyver_file)) end
  eco.declared = pinned or requires_python
  eco.installed = probe.version("python")
  local need = requires_python and version.parse(requires_python)
  if eco.installed and need and version.compare(eco.installed, need) < 0 then
    table.insert(eco.warnings, ("установлен Python %s, а проект требует %s"):format(eco.installed, requires_python))
  end
  local target = version.major_minor(pinned or eco.installed or requires_python)
  if target then
    table.insert(eco.targets, { lang = "python", version = target, label = "Python " .. target })
  end
  eco.language_version = target
  return eco
end

return M
