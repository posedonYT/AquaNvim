-- Официальные источники документации. Все URL можно переопределить в настройках:
--   require("aqua.ai").setup({ knowledge = { sources = { go = "https://mirror/doc/go{v}" } } })
local version = require("aqua.ai.stack.version")

local M = {}

local function mm(v) return version.major_minor(v) end
local function major(v) return version.major(v) end
local function full0(v)
  local p = version.parse(v)
  return p and ("%d.%d.0"):format(p.nums[1], p.nums[2] or 0)
end
local function std(v)
  return tostring(v):match("(%d+)")
end
local function exact(v) return version.clean(v) end

---@class aqua.knowledge.LangSpec
---@field url string шаблон: {v} — версия, {v_dash} — версия через «-»
---@field ver fun(v: string): string?
---@field label string
---@field format? "html"|"markdown"
---@field section? string шаблон заголовка раздела, который нужно вырезать из страницы

---@type table<string, aqua.knowledge.LangSpec>
M.languages = {
  go = { url = "https://go.dev/doc/go{v}", ver = mm, label = "Go {v}", format = "html" },
  python = { url = "https://docs.python.org/3/whatsnew/{v}.html", ver = mm, label = "Python {v}", format = "html" },
  node = { url = "https://nodejs.org/en/blog/release/v{v}.0.0", ver = major, label = "Node.js {v}", format = "html" },
  typescript = {
    url = "https://www.typescriptlang.org/docs/handbook/release-notes/typescript-{v_dash}.html",
    ver = mm, label = "TypeScript {v}", format = "html",
  },
  rust = {
    url = "https://raw.githubusercontent.com/rust-lang/rust/master/RELEASES.md",
    ver = full0, label = "Rust {v}", format = "markdown", section = "Version {v}",
  },
  ["c++"] = { url = "https://en.cppreference.com/w/cpp/{v}", ver = std, label = "C++{v}", format = "html" },
  c = { url = "https://en.cppreference.com/w/c/{v}", ver = std, label = "C{v}", format = "html" },
  gcc = { url = "https://gcc.gnu.org/gcc-{v}/changes.html", ver = major, label = "GCC {v}", format = "html" },
  clang = { url = "https://releases.llvm.org/{v}/tools/clang/docs/ReleaseNotes.html", ver = exact, label = "Clang {v}", format = "html" },
}

M.aliases = {
  golang = "go", py = "python", python3 = "python", nodejs = "node", ["node.js"] = "node", js = "node",
  javascript = "node", ts = "typescript", cpp = "c++", cxx = "c++", ["c++"] = "c++", rustc = "rust",
  ["llvm"] = "clang", ["g++"] = "gcc",
}

--- Канонический язык по имени или nil.
function M.language(name)
  name = (name or ""):lower()
  name = M.aliases[name] or name
  return M.languages[name] and name or nil
end

---@class aqua.knowledge.PkgSpec
---@field url string шаблон: {name}, {escaped} (Go: заглавные → !строчные), {v}
---@field latest? string
---@field format "html"|"markdown"|"json"

---@type table<string, aqua.knowledge.PkgSpec>
M.packages = {
  go = { url = "https://proxy.golang.org/{escaped}/@v/{v}.info", latest = "https://proxy.golang.org/{escaped}/@latest", format = "json" },
  npm = { url = "https://unpkg.com/{name}@{v}/README.md", latest = "https://unpkg.com/{name}/README.md", format = "markdown" },
  pypi = { url = "https://pypi.org/pypi/{name}/{v}/json", latest = "https://pypi.org/pypi/{name}/json", format = "json" },
  crates = { url = "https://crates.io/api/v1/crates/{name}/{v}/readme", latest = "https://crates.io/api/v1/crates/{name}", format = "html" },
}

--- Экосистема реестра пакетов для экосистемы стека.
M.registry_of = { go = "go", js = "npm", python = "pypi", rust = "crates" }

M.official_domains = {
  "go.dev", "proxy.golang.org", "pkg.go.dev",
  "docs.python.org", "pypi.org",
  "nodejs.org", "www.typescriptlang.org", "typescriptlang.org", "registry.npmjs.org", "unpkg.com",
  "raw.githubusercontent.com/rust-lang/", "doc.rust-lang.org", "blog.rust-lang.org", "crates.io", "docs.rs",
  "en.cppreference.com", "gcc.gnu.org", "releases.llvm.org", "clang.llvm.org",
}

local function escape_go(path)
  return (path:gsub("%u", function(c) return "!" .. c:lower() end))
end

--- Подставить значения в шаблон URL.
function M.fill(template, vars)
  return (template:gsub("{([%w_]+)}", function(k)
    local v = vars[k]
    return v ~= nil and tostring(v) or ("{" .. k .. "}")
  end))
end

--- URL заметок о выпуске языка.
---@return string? url, string? ver, aqua.knowledge.LangSpec? spec
function M.language_url(lang, v, overrides)
  local spec = M.languages[lang]
  if not spec then return nil end
  local ver = spec.ver(v)
  if not ver then return nil end
  local template = (overrides and overrides[lang]) or spec.url
  return M.fill(template, { v = ver, v_dash = ver:gsub("%.", "-") }), ver, spec
end

--- URL документации пакета.
---@return string? url, aqua.knowledge.PkgSpec? spec
function M.package_url(registry, name, v, overrides)
  local spec = M.packages[registry]
  if not spec then return nil end
  local template
  if v then
    template = (overrides and overrides[registry]) or spec.url
  else
    template = (overrides and overrides[registry .. "_latest"]) or spec.latest
  end
  return M.fill(template, { name = name, escaped = escape_go(name), v = v }), spec
end

--- Разрешён ли URL для «docs» (официальные домены; запись может содержать префикс пути).
function M.is_official(url, domains)
  local host, path = url:match("^https?://([^/:?#]+)[^/?#]*(/?[^?#]*)")
  if not host then return false end
  host = host:lower()
  for _, d in ipairs(domains or M.official_domains) do
    local dhost, dpath = d:match("^([^/]+)(.*)$")
    if dhost and (host == dhost:lower()) and (dpath == "" or (path or ""):sub(1, #dpath) == dpath) then
      return true
    end
  end
  return false
end

return M
