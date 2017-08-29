local libchest = require("libchest")
local libplace = require("libplace")
local libcapacity = require("libcapacity")
local component = require("component")
local computer = require("computer")
local sides = require("sides")
local robot = require("robot")
local term = require("term")
local util = require("util")

local libplan = {}

local plan_id = 1

local plan = {}

libplan.plan = plan

plan.mt = { __index = plan }

function disabled()
  assert(false, "Function disabled")
end

function plan.new(self, parent)
  local length = 1
  if parent then length = parent.length + 1 end
  
  local obj = {
    id = plan_id,
    parent = parent,
    masked = nil, -- recipe:index -> bool
    items = nil, -- name -> name, count, capacity
    length = length
  }
  
  if not parent then
    obj.items = {}
    local chestnames = libchest.list_chests()
    for k,v in ipairs(chestnames) do
      local info = libchest.get_info(v)
      for i = 1, info.capacity do
        local slot = info.slots[i]
        if slot.name then
          obj.items[slot.name] = (obj.items[slot.name] or 0) + slot.count
        end
      end
    end
  end
  
  plan_id = plan_id + 1
    
  -- for k,v in pairs(self) do obj[k] = v end
  -- obj.new = nil -- but not that one.
  setmetatable(obj, self.mt)
  obj.new = disabled
  
  return obj
end

-- root plan has no behavior
function plan.dump(self)
  assert(not self.parent, "dump function not implemented")
end

function plan.enact(self)
  assert(not self.parent, "enact function not implemented")
  return true
end

-- rebuild items
function plan.rebuild(self)
  assert(not self.parent, "rebuild function not implemented")
end

function plan.recipe_masked(self, item, index)
  local key = item..":"..index
  -- cache risks oom, trade time for memory
  -- if not self.masked then self.masked = {} end
  
  local obj = self
  while obj do
    if obj.masked and obj.masked[key] then
      -- self.masked[key] = true
      return true
    end
    obj = obj.parent
  end
  -- self.masked[key] = false
  return false
end

function plan.mask_recipe(self, item, index)
  local key = item..":"..index
  if not self.masked then self.masked = {} end
  self.masked[key] = true
end

function plan.reset(self)
  self.length = self.parent.length + 1
  self.items = nil
end

function plan.get_item_count(self, name)
  local obj = self
  while obj.parent and (not obj.items or not obj.items[name]) do
    obj = obj.parent
  end
  if obj.items then
    return obj.items[name] or 0
  else
    return 0
  end
end

function plan.set_item_count(self, name, count)
  assert(count >= 0)
  assert(self.parent, "don't set items manually on the root plan")
  if not self.items then self.items = {} end
  self.items[name] = count
end

local store = {}
libplan.store = store

for k,v in pairs(libplan.plan) do store[k] = v end
store.mt = { __index = store }

function store.new(self, parent, item_slot, name, count, capacity)
  local obj = libplan.plan.new(self, parent)
  obj.type = "store"
  obj.item_slot = item_slot
  obj.name = name
  obj.count = count
  obj.capacity = capacity
  obj:rebuild()
  return obj
end

function store.dump(self, marker)
  print(marker.."Store "..self.count.." "..self.name.." from "..self.item_slot)
end

function store.rebuild(self, depth)
  if depth and depth > 1 then self.parent:rebuild(depth - 1) end
  self.length = self.parent.length + 1
  local parval = self.parent:get_item_count(self.name)
  self:reset()
  self:set_item_count(self.name, parval + self.count)
end

local function exec_store(self, chest, slot, count)
  local ico = component.inventory_controller
  local myslot = ico.getStackInInternalSlot(self.item_slot)
  assert(myslot, "nothing in slot "..self.item_slot)
  util.check_stack(myslot)
  -- support aliasing ops before we have the deep optimizations to handle them cleanly
  -- assert(myslot.name == self.name, "told to store '"..self.name.."' but item is called '"..myslot.name.."'")
  assert(myslot.size >= count)
  -- damage only matters if maxDamage is set
  if not (myslot.maxDamage > 0 and myslot.damage > 0) then
    assert(myslot.maxSize >= self.capacity) -- adequately reported
  else
    assert(self.capacity == 1) -- cannot be grouped
  end
  
  local success, error = chest:store(slot, self.item_slot, self.name, count)
  if error then
    error = error .. " storing "..count.." "..self.name.." in "..slot
  end
  assert(success, error)
  
  local newslot = ico.getStackInInternalSlot(self.item_slot)
  local newsize = 0
  if newslot then newsize = newslot.size end
  assert(newsize == myslot.size - count)
end

function store.enact(self)
  local chestnames = libchest.list_chests()
  local count_left = self.count
  for _,chestname in ipairs(chestnames) do
    local chest = libchest.get_info(chestname)
    for i = 1, chest.capacity do
      local slot = chest.slots[i]
      if slot.name == self.name and slot.count < slot.capacity then
        local store_here = math.min(slot.capacity - slot.count, math.min(self.capacity, count_left))
        exec_store(self, chest, i, store_here)
        count_left = count_left - store_here
        if count_left == 0 then
          return true
        end
      end
    end
  end
  -- still have overflow, store in empty slot
  for _,chestname in ipairs(chestnames) do
    local chest = libchest.get_info(chestname)
    for i = 1, chest.capacity do
      local slot = chest.slots[i]
      if not slot.name then
        local store_here = math.min(self.capacity, count_left)
        exec_store(self, chest, i, store_here)
        count_left = count_left - store_here
        if count_left == 0 then
          return true
        end
      end
    end
  end
  -- fail!
  return nil,"ran out of free slots storing "..count_left.." "..self.name
end

local fetch = {}
libplan.fetch = fetch

for k,v in pairs(libplan.plan) do fetch[k] = v end
fetch.mt = { __index = fetch }

function fetch.new(self, parent, item_slot, name, count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "fetch"
  obj.item_slot = item_slot
  obj.name = name
  obj.count = count
  obj:rebuild()
  return obj
end

function fetch.dump(self, marker)
  print(marker.."Fetch "..self.count.." "..self.name.." to "..self.item_slot)
end

function fetch.rebuild(self, depth)
  if depth and depth > 1 then self.parent:rebuild(depth - 1) end
  local avail = self.parent:get_item_count(self.name)
  -- print("avail = "..avail.." for "..self.name..", request "..self.count)
  -- if avail < self.count then libplan.dump(self) end
  assert(avail >= self.count, "only "..avail.." "..self.name.." avail, need "..self.count)
  self:reset()
  self:set_item_count(self.name, avail - self.count)
end

function fetch.enact(self)
  local ico = component.inventory_controller
  local count_left = self.count
  local chestnames = libchest.list_chests()
  -- search through chests for a slot containing the item
  -- if found, fetch as many items as are there
  -- repeat until run out or count satisfied
  for _,chestname in ipairs(chestnames) do
    local chest = libchest.get_info(chestname)
    for i = 1, chest.capacity do
      local slot = chest.slots[i]
      if slot.name == self.name then
        local grab_here = math.min(count_left, slot.count)
        
        local oldslot = ico.getStackInInternalSlot(self.item_slot)
        local oldslot_size = 0
        if oldslot then oldslot_size = oldslot.size end
        
        assert(chest:grab(i, self.item_slot, self.name, grab_here))
        
        local newslot = ico.getStackInInternalSlot(self.item_slot)
        local newslot_size = 0
        if newslot then newslot_size = newslot.size end
        
        assert(newslot_size == oldslot_size + grab_here)
        
        count_left = count_left - grab_here
        if count_left == 0 then
          return true
        end
      end
    end
  end
  return nil, "failed to fetch "..count_left.." "..self.name
end

local craft = {}
libplan.craft = craft

for k,v in pairs(libplan.plan) do craft[k] = v end
craft.mt = { __index = craft }

-- note: count is the number of items PRODUCED, not consumed!
function craft.new(self, parent, item_slot, name, count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "craft"
  obj.item_slot = item_slot
  obj.name = name
  obj.count = count
  obj:rebuild()
  return obj
end

function craft.dump(self, marker)
  print(marker.."Craft "..self.count.." "..self.name.." in "..self.item_slot)
end

function craft.rebuild(self, depth)
  if depth and depth > 1 then self.parent:rebuild(depth - 1) end
  self:reset()
end

function craft.enact(self)
  local ico = component.inventory_controller
  
  local oldslot = ico.getStackInInternalSlot(self.item_slot)
  local oldslot_size = 0
  if oldslot then oldslot_size = oldslot.size end
  
  local crafting = component.crafting
  robot.select(self.item_slot)
  assert(crafting.craft(self.count))
  
  local newslot = ico.getStackInInternalSlot(self.item_slot)
  local newslot_size = 0
  if newslot then newslot_size = newslot.size end
  
  assert(newslot_size == self.count, "crafting "..self.name.." failed: expected "..self.count..", got "..newslot_size)
  return true
end

local move = {}
libplan.move = move

for k,v in pairs(libplan.plan) do move[k] = v end
move.mt = { __index = move }

function move.new(self, parent, from_slot, to_slot, count)
  assert(parent and from_slot and to_slot and count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "move"
  obj.from_slot = from_slot
  obj.to_slot = to_slot
  obj.count = count
  obj:rebuild()
  return obj
end

function move.dump(self, marker)
  print(marker.."Move "..self.count.." from "..self.from_slot.." to "..self.to_slot)
end

function move.rebuild(self, depth)
  if depth and depth > 1 then self.parent:rebuild(depth - 1) end
  self:reset()
end

function move.enact(self)
  robot.select(self.from_slot)
  assert(robot.transferTo(self.to_slot, self.count))
  return true
end

local drop = {}
libplan.drop = drop

for k,v in pairs(libplan.plan) do drop[k] = v end
drop.mt = { __index = drop }

function drop.new(self, parent, item_slot, location, direction, name, count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "drop"
  obj.item_slot = item_slot
  obj.location = location
  obj.name = name
  obj.count = count
  obj.direction = direction
  obj:rebuild()
  return obj
end

function drop.dump(self, marker)
  print(marker.."Drop "..self.count.." "..self.name.." from "..self.item_slot.." at "..self.location)
end

function drop.rebuild(self, depth)
  if depth and depth > 1 then self.parent:rebuild(depth - 1) end
  self:reset()
end

function drop.enact(self)
  robot.select(self.item_slot)
  
  local ico = component.inventory_controller
  local oldslot = ico.getStackInInternalSlot(self.item_slot)
  local oldslot_size = 0
  if oldslot then oldslot_size = oldslot.size end
  if oldslot_size < self.count then
    print("slot error: told to drop "..self.count.." from "..self.item_slot.." but only had "..oldslot_size)
    os.exit()
  end
  
  libplace.go_to(self.location)
  
  local dirmap = {forward=robot.drop, down=robot.dropDown}
  local dropfn = dirmap[self.direction]
  
  if not dropfn(self.count) then
    print("error: cannot drop "..self.count.." from "..self.item_slot)
    os.exit()
  end
  -- assert(robot.dropDown(self.count))
  
  local newslot = ico.getStackInInternalSlot(self.item_slot)
  local newslot_size = 0
  if newslot then newslot_size = newslot.size end
  
  assert(newslot_size == oldslot_size - self.count, "only down to "..newslot_size.." dropping "..self.count.." from "..oldslot_size)
  
  return true
end

local suck = {}
libplan.suck = suck

for k,v in pairs(libplan.plan) do suck[k] = v end
suck.mt = { __index = suck }

function suck.new(self, parent, item_slot, location, direction, name, count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "suck"
  obj.item_slot = item_slot
  obj.location = location
  obj.direction = direction
  obj.name = name
  obj.count = count
  obj:rebuild()
  return obj
end

function suck.dump(self, marker)
  print(marker.."Suck "..self.count.." "..self.name.." to "..self.item_slot.." at "..self.location)
end

function suck.rebuild(self, depth)
  if depth and depth > 1 then self.parent:rebuild(depth - 1) end
  self:reset()
end

function suck.enact(self)
  if not self.count then return true end
  
  libplace.go_to(self.location)
  local ico = component.inventory_controller
  local oldslot = ico.getStackInInternalSlot(self.item_slot)
  local oldslot_size = 0
  if oldslot then oldslot_size = oldslot.size end
  
  robot.select(self.item_slot)
  
  local remaining = self.count
  
  while remaining > 0 do 
    if self.direction == "forward" then
      robot.suck(remaining)
    elseif self.direction == "up" then
      robot.suckUp(remaining)
    else
      assert(false, "unknown suck direction '"..self.direction.."'")
    end
    
    local newslot = ico.getStackInInternalSlot(self.item_slot)
    local newslot_size = 0
    if newslot then newslot_size = newslot.size end
    
    local items_gained = newslot_size - oldslot_size
    assert(items_gained <= self.count)
    
    remaining = self.count - items_gained
  end
  
  return true
end

function libplan.action_fetch(plan, item_slot, name, count, capacity)
  assert(name and count and capacity)
  assert(count <= capacity, "asked to fetch "..count.." "..name..", which exceeds cap "..capacity)
  local avail = plan:get_item_count(name)
  if avail >= count then
    return libplan.fetch:new(plan, item_slot, name, count, capacity)
  end
  return nil,"not enough items found fetching "..count.." "..name
end

function libplan.action_move(plan, from_slot, to_slot, count)
  assert(plan and from_slot and to_slot and count)
  return libplan.move:new(plan, from_slot, to_slot, count)
end

-- return new plan or nil,error if failed
-- capacity override so damaged items can be stored as stack=1
function libplan.action_store(plan, item_slot, name, count, capacity)
  assert(item_slot and name and count and capacity)
  -- search through chests for a slot containing the item and not full
  -- if found, store as many items as fit
  -- if items left over, store in a free slot
  return libplan.store:new(plan, item_slot, name, count, capacity)
end

-- rather trivial, since it has little logic of its own because its items are assumed to be provided by fetch actions
function libplan.action_craft(plan, slot, name, count)
  return libplan.craft:new(plan, slot, name, count)
end

function libplan.action_drop(plan, direction, slot, location, name, count)
  assert(direction == "forward" or direction == "down")
  assert(slot and location and name and count)
  return libplan.drop:new(plan, slot, location, direction, name, count)
end

function libplan.action_suck(plan, direction, slot, location, name, count)
  assert(direction == "forward" or direction == "up")
  return libplan.suck:new(plan, slot, location, direction, name, count)
end

function libplan.plan_to_list(plan)
  -- invert order
  local i = 0
  local list = nil
  while plan do
    list = {plan = plan, next = list}
    plan = plan.parent
    i = i + 1
  end
  return list, i
end

function libplan.dump_list(list, focus)
  local i = 1
  while list do
    if not focus or (i > focus - 5 and i < focus + 5) then
      if i == focus then
        list.plan:dump((i-1).."> ")
      else
        list.plan:dump((i-1)..": ")
      end
    end
    list = list.next
    i = i + 1
  end
end

function libplan.dump(plan, focus)
  print("Plan:")
  libplan.dump_list(libplan.plan_to_list(plan), focus)
end

function libplan.dump_tail(plan, focus)
  local i
  local list
  list, i = libplan.plan_to_list(plan)
  print("Plan:")
  libplan.dump_list(list, i)
end

local function same_machine(loc1, loc2)
  local name1 = util.slice(loc1, ":")
  local name2 = util.slice(loc2, ":")
  return name1 == name2
end

local function in_craft_grid(slot)
  if slot >= 1 and slot <= 3 then return true end
  if slot >= 5 and slot <= 7 then return true end
  if slot >= 9 and slot <= 11 then return true end
  return false
end

-- optimizes just the current step of the plan!
function libplan.opt1(plan)
  -- move to direct placement
  if plan.type == "move" then
    if plan.parent.type == "fetch" and plan.parent.item_slot == plan.from_slot and plan.parent.count == plan.count then
      plan.parent.item_slot = plan.to_slot
      return plan.parent
    end
    if plan.parent.type == "craft" and plan.parent.item_slot == plan.from_slot and plan.parent.count == plan.count then
      plan.parent.item_slot = plan.to_slot
      return plan.parent
    end
    if plan.parent.type == "suck" and plan.parent.item_slot == plan.from_slot and plan.parent.count == plan.count then
      plan.parent.item_slot = plan.to_slot
      return plan.parent
    end
    if plan.parent.type == "suck" and plan.parent.item_slot == plan.from_slot and plan.parent.count > plan.count then
      plan.parent.count = plan.parent.count - plan.count
      local error
      plan, error = libplan.action_suck(plan.parent, plan.to_slot, plan.parent.location, plan.parent.name, plan.count)
      assert(plan, error)
      return libplan.opt1(plan)
    end
  end
  
  local function swap()
    local plan = plan
    local newplan = plan.parent
    plan.parent = plan.parent.parent
    plan:rebuild()
    plan = libplan.opt1(plan)
    newplan.parent = plan
    newplan:rebuild()
    newplan = libplan.opt1(newplan)
    return newplan
  end
  
  -- simple combination
  if plan.type == "fetch" and plan.parent.type == "fetch"
    and plan.name == plan.parent.name
    and plan.count + plan.parent.count <= libcapacity.get_capacity(plan.name)
  then
    if plan.item_slot == plan.parent.item_slot then
      plan.parent.count = plan.parent.count + plan.count
      plan.parent:rebuild()
      return libplan.opt1(plan.parent)
    else
      -- load many items at once
      plan.parent.count = plan.parent.count + plan.count
      plan.parent:rebuild()
      local new_plan = libplan.opt1(plan.parent)
      new_plan = libplan.move:new(new_plan, plan.parent.item_slot, plan.item_slot, plan.count)
      new_plan:rebuild()
      return libplan.opt1(new_plan)
    end
  end
  
  -- helper for the above, swap fetch and move if easy
  if plan.type == "fetch" and plan.parent.type == "move"
    and not(plan.parent.from_slot == plan.item_slot or plan.parent.to_slot == plan.item_slot)
  then
    return swap()
  end
  
  if plan.parent.type == "store" and plan.type == "drop"
  then
    return swap()
  end
  
  if plan.parent.type == "suck" and plan.type == "drop"
    and not same_machine(plan.parent.location, plan.location)
    and not (plan.parent.item_slot == plan.item_slot)
  then
    return swap()
  end
  
  -- try to find a matching store parent
  if plan.type == "fetch" then
    local match = plan.parent
    local pred = plan
    local i = 1
    while match do
      -- can only search past fetches and stores
      if not (match.type == "fetch" or match.type == "store" or match.type == "move") then break end
      if match.type == "move" then
        if plan.item_slot == match.from_slot or plan.item_slot == match.to_slot then
          -- slot collision
          break
        end
      else
        if match.type == "store"
          and plan.name == match.name
        then
          local items_still_stored = math.max(0, match.count - plan.count)
          local items_still_fetched = math.max(0, plan.count - match.count)
          local original_match_count = match.count
          
          -- matches us, cut match out
          local new_plan
          if items_still_stored == 0 then
            new_plan = match.parent
          else
            new_plan = match
            match.count = items_still_stored
          end
          
          if not (plan.item_slot == match.item_slot) then
            new_plan = libplan.move:new(new_plan, match.item_slot, plan.item_slot, math.min(plan.count, original_match_count))
            -- plan:dump("#")
            -- print("move "..plan.count.." "..match.name.." from "..match.item_slot.." to "..plan.item_slot)
            new_plan = libplan.opt1(new_plan)
            -- libplan.dump(new_plan)
          end
          pred.parent = new_plan
          
          local res
          if items_still_fetched == 0 then
            res = plan.parent
          else
            plan.count = items_still_fetched
            res = plan
          end
          res:rebuild(i + 3)
          return libplan.opt1(res)
        end
        if plan.item_slot == match.item_slot then
          -- slot collision
          break
        end
      end
      pred = match
      match = match.parent
      i = i + 1
    end
  end
  
  -- fuse move-drop into drop
  if plan.parent
    and plan.parent.type == "move" and plan.type == "drop"
    and plan.parent.to_slot == plan.item_slot
    and plan.parent.count == plan.count
  then
    plan.item_slot = plan.parent.from_slot
    plan.parent = plan.parent.parent
    plan:rebuild()
    plan = libplan.opt1(plan)
    return plan
  end
  
  return plan
end

function libplan.enact(plan)
  print("Enact.")
  local full_list, length = libplan.plan_to_list(plan)
  local list = full_list
  local i = 1
  while list do
    term.clear()
    print(computer.freeMemory().." / "..computer.totalMemory().." | "..(i - 1).." / "..(length - 1))
    libplan.dump_list(full_list, i)
    local success, error = list.plan:enact()
    if not success then
      print("Plan failed: "..error)
      assert(false)
    end
    list = list.next
    i = i + 1
  end
end

return libplan
