-- Минимальный разбор TOML — ровно столько, сколько нужно для pyproject.toml, Cargo.toml,
-- Cargo.lock, uv.lock, poetry.lock, rust-toolchain.toml: таблицы, массивы таблиц, строки,
-- числа, булевы, массивы (в т. ч. многострочные), простые inline-таблицы.
local M = {}

local function strip_comment(line)
  local out, in_str, q = {}, false, nil
  for i = 1, #line do
    local c = line:sub(i, i)
    if in_str then
      out[#out + 1] = c
      if c == q and line:sub(i - 1, i - 1) ~= "\\" then in_str = false end
    elseif c == '"' or c == "'" then
      in_str, q = true, c
      out[#out + 1] = c
    elseif c == "#" then
      break
    else
      out[#out + 1] = c
    end
  end
  return vim.trim(table.concat(out))
end

local parse_value

--- Разбор значения из начала строки s. Возвращает value, остаток.
function parse_value(s)
  s = vim.trim(s)
  local c = s:sub(1, 1)
  if s:sub(1, 3) == '"""' or s:sub(1, 3) == "'''" then
    local q = s:sub(1, 3)
    local e = s:find(q, 4, true)
    return e and s:sub(4, e - 1) or s:sub(4), e and s:sub(e + 3) or ""
  elseif c == '"' then
    local i, buf = 2, {}
    while i <= #s do
      local ch = s:sub(i, i)
      if ch == "\\" then
        buf[#buf + 1] = s:sub(i + 1, i + 1)
        i = i + 2
      elseif ch == '"' then
        return table.concat(buf), s:sub(i + 1)
      else
        buf[#buf + 1] = ch
        i = i + 1
      end
    end
    return table.concat(buf), ""
  elseif c == "'" then
    local e = s:find("'", 2, true)
    return s:sub(2, (e or #s + 1) - 1), e and s:sub(e + 1) or ""
  elseif c == "[" then
    local arr, rest = {}, s:sub(2)
    while true do
      rest = vim.trim(rest)
      if rest == "" then return arr, "" end
      if rest:sub(1, 1) == "]" then return arr, rest:sub(2) end
      if rest:sub(1, 1) == "," then
        rest = rest:sub(2)
      else
        local v
        v, rest = parse_value(rest)
        arr[#arr + 1] = v
      end
    end
  elseif c == "{" then
    local tbl, rest = {}, s:sub(2)
    while true do
      rest = vim.trim(rest)
      if rest == "" then return tbl, "" end
      if rest:sub(1, 1) == "}" then return tbl, rest:sub(2) end
      if rest:sub(1, 1) == "," then
        rest = rest:sub(2)
      else
        local key, after = rest:match('^"?([%w%-_%.]+)"?%s*=%s*(.*)$')
        if not key then return tbl, "" end
        local v
        v, rest = parse_value(after)
        tbl[key] = v
      end
    end
  elseif s:match("^true") then
    return true, s:sub(5)
  elseif s:match("^false") then
    return false, s:sub(6)
  end
  local num, rest = s:match("^([%+%-]?[%d_%.eE]+)(.*)$")
  if num then
    return tonumber((num:gsub("_", ""))) or num, rest
  end
  local word, rest2 = s:match("^([^,%]}%s]+)(.*)$")
  return word, rest2 or ""
end

--- Вложенная таблица по пути "a.b.c" (создаёт недостающие).
local function at(root, path)
  local t = root
  for key in path:gmatch('[^%.]+') do
    key = key:gsub('^"', ""):gsub('"$', "")
    t[key] = t[key] or {}
    t = t[key]
  end
  return t
end

--- Разобрать TOML-текст в таблицу Lua.
---@param text string
function M.parse(text)
  local root = {}
  local cur = root
  local pending -- незакрытое многострочное значение: { key, buf }
  local lines = vim.split(text or "", "\n", { plain = true })
  for _, raw in ipairs(lines) do
    local line = strip_comment(raw)
    if pending then
      pending.buf = pending.buf .. " " .. line
      local _, depth = pending.buf:gsub("%[", "")
      local _, closed = pending.buf:gsub("%]", "")
      if closed >= depth then
        pending.tbl[pending.key] = (parse_value(pending.buf))
        pending = nil
      end
    elseif line ~= "" then
      local arr_tbl = line:match("^%[%[%s*([^%]]+)%s*%]%]$")
      local tbl = not arr_tbl and line:match("^%[%s*([^%]]+)%s*%]$")
      if arr_tbl then
        local parent_path, last = arr_tbl:match("^(.*)%.([^%.]+)$")
        local parent = parent_path and at(root, parent_path) or root
        last = last or arr_tbl
        parent[last] = parent[last] or {}
        local item = {}
        table.insert(parent[last], item)
        cur = item
      elseif tbl then
        cur = at(root, tbl)
      else
        local key, value = line:match('^"?([^"=]-)"?%s*=%s*(.*)$')
        if key then
          key = vim.trim(key)
          local target = cur
          local dotted_parent, dotted_last = key:match("^(.*)%.([^%.]+)$")
          if dotted_parent and not key:find('"') then
            target = at(cur, dotted_parent)
            key = dotted_last
          end
          local opens = select(2, value:gsub("%[", "")) + select(2, value:gsub("{", ""))
          local closes = select(2, value:gsub("%]", "")) + select(2, value:gsub("}", ""))
          if (value:sub(1, 1) == "[" or value:sub(1, 1) == "{") and closes < opens then
            pending = { tbl = target, key = key, buf = value }
          else
            target[key] = (parse_value(value))
          end
        end
      end
    end
  end
  return root
end

return M
