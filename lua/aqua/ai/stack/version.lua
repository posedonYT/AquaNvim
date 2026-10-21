-- Версии: разбор и сравнение. Понимает "1.27", "go1.27.2", "v9.7.0", "1.27rc1",
-- диапазоны "^4.21.0", "~1.2", ">=3.12,<4", "~=3.12", "3.12.*", "==2.0".
local M = {}

---@class aqua.Version
---@field nums integer[]
---@field pre? string
---@field raw string

--- Первая версия из строки (для диапазона — его нижняя граница).
---@param s? string
---@return aqua.Version?
function M.parse(s)
  if type(s) ~= "string" then
    return nil
  end
  local str = s:match("(%d+[%d%.]*[%w%-%.%+]*)")
  if not str then
    return nil
  end
  local nums_part, rest = str:match("^([%d%.]+)(.*)$")
  local nums = {}
  for n in nums_part:gmatch("%d+") do
    nums[#nums + 1] = tonumber(n)
  end
  if #nums == 0 then
    return nil
  end
  local pre = rest:match("^%-?([%a][%w%.]*)") -- rc1, beta.2, -alpha
  return { nums = nums, pre = pre ~= "" and pre or nil, raw = s }
end

--- -1 / 0 / 1. Отсутствующие компоненты считаются нулями; предрелиз меньше релиза.
function M.compare(a, b)
  a = type(a) == "table" and a or M.parse(a)
  b = type(b) == "table" and b or M.parse(b)
  if not a or not b then
    return 0
  end
  for i = 1, math.max(#a.nums, #b.nums) do
    local x, y = a.nums[i] or 0, b.nums[i] or 0
    if x ~= y then
      return x < y and -1 or 1
    end
  end
  if a.pre and not b.pre then return -1 end
  if b.pre and not a.pre then return 1 end
  if a.pre and b.pre and a.pre ~= b.pre then
    return a.pre < b.pre and -1 or 1
  end
  return 0
end

--- "1.27.2" → "1.27"
function M.major_minor(s)
  local v = type(s) == "table" and s or M.parse(s)
  if not v then return nil end
  return ("%d.%d"):format(v.nums[1], v.nums[2] or 0)
end

--- "24.11.0" → "24"
function M.major(s)
  local v = type(s) == "table" and s or M.parse(s)
  return v and tostring(v.nums[1]) or nil
end

--- Каноническая строка "1.27.2" (без префиксов).
function M.clean(s)
  local v = type(s) == "table" and s or M.parse(s)
  if not v then return nil end
  local parts = vim.tbl_map(tostring, v.nums)
  return table.concat(parts, ".") .. (v.pre and ("-" .. v.pre) or "")
end

return M
