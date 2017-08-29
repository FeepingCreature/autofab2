local util = require("util")

local config_file = "capacity.db"

local libcapacity = {}

local cache = {}

local cfg = util.config(config_file)

function libcapacity.get_capacity(id)
  if cache[id] then return cache[id] end
  local res = cfg:get(id)
  if res then
    res = tonumber(res)
  else
    print("WARN: unknown capacity for '"..id.."', guessing 1")
    res = 1
  end
  cache[id] = res
  return res
end

function libcapacity.set_capacity(id, cap)
  cache[id] = cap
  
  local existing = cfg:get(id)
  if not (cap == existing) then
    cfg:set(id, tostring(cap))
    -- save
    cfg:close()
    cfg = util.config(config_file)
  end
end

return libcapacity
