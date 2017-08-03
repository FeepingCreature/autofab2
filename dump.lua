local libplan = require("libplan")
local libnav = require("libnav")
local robot = require("robot")
local util = require("util")
local component = require("component")

util.init()

local ico = component.inventory_controller

local args = { ... }

local function help()
  print("Usage:")
  print("  dump")
  print("  Dumps/sorts all items in the robot's inventory into chests")
end

if not(#args == 0) then
  help()
  return
end

local plan = libplan.plan:new()

for i=1, robot.inventorySize() do
  local slot = ico.getStackInInternalSlot(i)
  if slot then
    util.check_stack(slot)
    local capacity = slot.maxSize
    plan = libplan.action_store(plan, i, slot.name, slot.size, capacity)
  end
end

local backup = libnav.get_location()

libplan.enact(plan)

libnav.go_to(backup)
libnav.flush()
