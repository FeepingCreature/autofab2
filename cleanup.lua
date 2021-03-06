local libchest = require("libchest")
local libplan = require("libplan")
local libnav = require("libnav")
local robot = require("robot")
local util = require("util")
local component = require("component")
local librecipe = require("librecipe")

util.init()

local ico = component.inventory_controller

local args = { ... }

local function help()
  print("Usage:")
  print("  cleanup")
  print("  Reinventorizes all items in all chests.")
end

if not(#args == 0) then
  help()
  return
end

local backup = libnav.get_location()

local chestnames = libchest.list_chests()
for k,v in pairs(chestnames) do
  local info = libchest.get_info(v)
  for i = 1, info.capacity do
    local slot = info.slots[i]
    if slot.name then
      local is_known = librecipe.reverse_name(slot.name, true)
      if not is_known then
        print("No alias defined for '"..slot.name.."'!")
      end
      local plan, error = libplan.plan:new()
      plan, error = libplan.action_fetch(plan, 1, slot.name, slot.count, slot.count)
      assert(plan, error)
      libplan.enact(plan, true)
      
      local stack = ico.getStackInInternalSlot(1)
      assert(stack)
      util.check_stack(stack)
      plan = libplan.plan:new()
      plan, error = libplan.action_store(plan, 1, stack.name, stack.size, stack.maxSize)
      assert(plan, error)
      libplan.enact(plan, true)
    end
  end
end

libnav.go_to(backup)
libnav.flush()
