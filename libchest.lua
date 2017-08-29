local util = require("util")
local shell = require("shell")
local robot = require("robot")
local libnav = require("libnav")
local libplace = require("libplace")
local filesystem = require("filesystem")
local libcapacity = require("libcapacity")
local component = require("component")
local sides = require("sides")

local libchest = {}

local chest_dir = shell.getWorkingDirectory().."/chests"
local chests_cfg = chest_dir.."/chests.txt"

if not filesystem.isDirectory(chest_dir) then
  assert(filesystem.makeDirectory(chest_dir))
end

local function db_file(chest)
  return chest_dir.."/"..chest..".db"
end

local function format_slot(stack, name)
  if not stack then
    return ""
  end
  util.check_stack(stack)
  if not name then name = stack.name end
  local format_name = stack.name
  if not (stack.name == name) then
    format_name = name
  end -- force specified name (for aliasing support)
  local count = stack.size
  local maxsize = stack.maxSize
  -- set capacity for original name, not aliased name
  libcapacity.set_capacity(name, maxsize)
  return "" .. format_name .. " | " .. count .. " | " .. maxsize
end

local function parse_slot(slot)
  if slot:len() == 0 then
    return {
      name = nil,
      count = 0,
      capacity = 0
    }
  end
  
  local parts = util.split_sa(slot, "|")
  assert(#parts == 3, "invalid slot data")
  return {
    name = parts[1],
    count = tonumber(parts[2]),
    capacity = tonumber(parts[3])
  }
end

function libchest.define(name, location)
  assert(name and location)
  
  -- add chest
  local chestmap = util.split_so(util.config_get(chests_cfg, "chests", ""), "|")
  assert(not chestmap[name], "Chest already defined")
  chestmap[name] = true
  
  -- gonna go have a look
  local backup = libnav.get_location()
  libplace.go_to(location)
  util.config_set(chests_cfg, "chests", util.join_so(chestmap, "|"))
  -- create chest file
  local ico = component.inventory_controller
  local capacity = ico.getInventorySize(sides.front)
  local cfg = util.config(db_file(name))
  cfg:set("location", location)
  cfg:set("capacity", capacity)
  -- read out initial state
  for i = 1, capacity do
    local stack = ico.getStackInSlot(sides.front, i)
    local info = format_slot(stack)
    cfg:set("slot "..i, info)
  end
  cfg:close()
  -- go back where we were
  libnav.go_to(backup)
  libnav.flush()
end

function libchest.list_chests()
  return util.split_sa(util.config_get(chests_cfg, "chests", ""), "|")
end

function libchest.get_info(name)
  local cfg = util.config(db_file(name))
  assert(not cfg.fresh, "uninitialized chest queried: '"..name.."'")
  local location = cfg:get("location")
  local capacity = tonumber(cfg:get("capacity"))
  local slots = {}
  for i = 1, capacity do
    local info = cfg:get("slot "..i)
    slots[i] = parse_slot(info)
  end
  cfg:close()
  
  obj = {
    name = name,
    location = location,
    capacity = capacity,
    slots = slots
  }
  
  -- store up to count
  function obj.store(self, slot, item_slot, name, count)
    local ico = component.inventory_controller
    libplace.go_to(self.location)
    robot.select(item_slot)
    -- capture possible tuple
    local res = table.pack(ico.dropIntoSlot(sides.forward, slot, count))
    if res[1] then
      -- write change
      local stack = ico.getStackInSlot(sides.front, slot)
      util.config_set(db_file(self.name), "slot "..slot, format_slot(stack, name))
    end
    return table.unpack(res)
  end
  
  -- grab up to count
  function obj.grab(self, slot, item_slot, name, count)
    local ico = component.inventory_controller
    libplace.go_to(self.location)
    robot.select(item_slot)
    -- capture possible tuple
    local res = table.pack(ico.suckFromSlot(sides.front, slot, count))
    if res[1] then
      -- write change
      local stack = ico.getStackInSlot(sides.front, slot)
      util.config_set(db_file(self.name), "slot "..slot, format_slot(stack, name))
    end
    return table.unpack(res)
  end
  
  return obj
end

return libchest
