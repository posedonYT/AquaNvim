-- Rust: Cargo.toml, Cargo.lock, rust-toolchain(.toml), установленный rustc.
local version = require("aqua.ai.stack.version")
local probe = require("aqua.ai.stack.probe")
local toml = require("aqua.ai.stack.toml")

local M = {}

---@param ctx aqua.stack.Ctx
function M.detect(ctx)
  local cargo = ctx.files["Cargo.toml"] and ctx.files["Cargo.toml"][1]
  if not cargo then return nil end
  local dir = vim.fs.dirname(cargo)
  local data = toml.parse(ctx.read(cargo) or "")
  local pkg = data.package or (data.workspace and data.workspace.package) or {}
  local eco = {
    id = "rust", name = "Rust", manifests = { ctx.rel(cargo) }, deps = {}, warnings = {}, targets = {}, dir = dir,
    edition = pkg.edition, indirect_count = 0,
  }

  local resolved = {}
  local lock = ctx.read(dir .. "/Cargo.lock")
  if lock then
    table.insert(eco.manifests, ctx.rel(dir .. "/Cargo.lock"))
    for _, p in ipairs(toml.parse(lock).package or {}) do
      if type(p) == "table" and p.name then resolved[p.name] = resolved[p.name] or p.version end
    end
  end
  local function add(tbl, dev)
    local names = vim.tbl_keys(type(tbl) == "table" and tbl or {})
    table.sort(names)
    for _, n in ipairs(names) do
      local spec = tbl[n]
      local req = type(spec) == "table" and (spec.version or (spec.path and "path") or (spec.git and "git")) or spec
      table.insert(eco.deps, { name = n, version = resolved[n] or req, range = req, direct = true, dev = dev or nil })
    end
  end
  add(data.dependencies, false)
  add(data["dev-dependencies"], true)
  add(data.workspace and data.workspace.dependencies, false)

  local channel
  local tc = ctx.read(dir .. "/rust-toolchain.toml")
  if tc then
    table.insert(eco.manifests, ctx.rel(dir .. "/rust-toolchain.toml"))
    channel = (toml.parse(tc).toolchain or {}).channel
  else
    local plain = ctx.read(dir .. "/rust-toolchain")
    channel = plain and vim.trim(plain:match("[^\n]*"))
  end
  eco.toolchain = channel
  eco.declared = pkg["rust-version"] or (channel and version.parse(channel) and channel) or nil
  eco.installed = probe.version("rustc")
  if eco.installed and pkg["rust-version"] and version.compare(eco.installed, pkg["rust-version"]) < 0 then
    table.insert(eco.warnings, ("установлен rustc %s, а rust-version = %s"):format(eco.installed, pkg["rust-version"]))
  end
  local v = version.parse(eco.installed or eco.declared)
  if v then
    local full = ("%d.%d.0"):format(v.nums[1], v.nums[2] or 0)
    table.insert(eco.targets, { lang = "rust", version = full, label = "Rust " .. version.major_minor(v) })
    eco.language_version = version.major_minor(v)
  end
  return eco
end

return M
