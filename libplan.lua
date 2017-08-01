local libchest = require("libchest")
local libplace = require("libplace")
local component = require("component")
local sides = require("sides")
local robot = require("robot")
local util = require("util")

local libplan = {}

local function make_store_model(parent)
  local obj = {
    parent = parent,
    items = nil -- name -> name, count, capacity
  }
  if not parent then
    -- generate root info
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
  
  function obj.reset(self, parent)
    self.parent = parent
    self.items = nil
  end
  function obj.get_item_count(self, name)
    local obj = self
    while obj.parent and (not obj.items or not obj.items[name]) do
      obj = obj.parent
    end
    return obj.items[name] or 0
  end
  function obj.set_item_count(self, name, count)
    assert(count >= 0)
    if not self.items then self.items = {} end
    self.items[name] = count
  end
  return obj
end

local plan_id = 1

function libplan.plan_create(parent)
  -- root plan has no behavior
  local root_plan = not parent
  local parent_model
  if parent then parent_model = parent.model end
  
  local obj = {
    id = plan_id,
    parent = parent,
    model = make_store_model(parent_model)
  }
  plan_id = plan_id + 1
  
  function obj.dump(self)
    assert(root_plan, "dump function not implemented")
  end
  function obj.enact(self)
    assert(root_plan, "enact function not implemented")
    return true
  end
  -- rebuild items
  function obj.rebuild(self)
    assert(root_plan, "rebuild function not implemented")
    -- self.model = make_store_model() -- no need, no changes
  end
  return obj
end

local function setup_store(plan, item_slot_, name_, count_, capacity_)
  plan.type = "store"
  plan.item_slot = item_slot_
  plan.name = name_
  plan.count = count_
  plan.capacity = capacity_
  function plan.dump(self, marker)
    print(marker.."Store "..self.count.." "..self.name.." from "..self.item_slot)
  end
  function plan.rebuild(self, recursive)
    if recursive then self.parent:rebuild(true) end
    local parval = self.parent.model:get_item_count(self.name)
    self.model:reset(self.parent.model)
    self.model:set_item_count(self.name, parval + self.count)
  end
  local function store(self, chest, slot, count)
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
    
    success, error = chest:store(slot, self.item_slot, self.name, count)
    if error then
      error = error .. " storing "..count.." "..self.name.." in "..slot
    end
    assert(success, error)
    
    local newslot = ico.getStackInInternalSlot(self.item_slot)
    local newsize = 0
    if newslot then newsize = newslot.size end
    assert(newsize == myslot.size - count)
  end
  function plan.enact(self)
    local chestnames = libchest.list_chests()
    local count_left = self.count
    for _,chestname in ipairs(chestnames) do
      local chest = libchest.get_info(chestname)
      for i = 1, chest.capacity do
        local slot = chest.slots[i]
        if slot.name == self.name and slot.count < slot.capacity then
          local store_here = math.min(slot.capacity - slot.count, math.min(self.capacity, count_left))
          store(self, chest, i, store_here)
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
          store(self, chest, i, store_here)
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
end

local function setup_fetch(plan, item_slot_, name_, count_)
  plan.type = "fetch"
  plan.item_slot = item_slot_
  plan.name = name_
  plan.count = count_
  function plan.dump(self, marker)
    print(marker.."Fetch "..self.count.." "..self.name.." to "..self.item_slot)
  end
  function plan.rebuild(self, recursive)
    if recursive then self.parent:rebuild(true) end
    local avail = self.parent.model:get_item_count(self.name)
    -- print("avail = "..avail.." for "..self.name..", request "..self.count)
    assert(avail >= self.count, "only "..avail.." "..self.name.." avail, need "..self.count)
    self.model:reset(self.parent.model)
    self.model:set_item_count(self.name, avail - self.count)
  end
  function plan.enact(self)
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
end

-- note: count is the number of items PRODUCED, not consumed!
local function setup_craft(plan, item_slot_, name_, count_)
  plan.type = "craft"
  plan.item_slot = item_slot_
  plan.name = name_
  plan.count = count_
  function plan.dump(self, marker)
    print(marker.."Craft "..self.count.." "..self.name.." in "..self.item_slot)
  end
  function plan.rebuild(self, recursive)
    if recursive then self.parent:rebuild(true) end
    self.model:reset(self.parent.model)
  end
  function plan.enact(self)
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
    
    assert(newslot_size == self.count)
    return true
  end
end

local function setup_move(plan, from_slot_, to_slot_, count_)
  plan.type = "move"
  plan.from_slot = from_slot_
  plan.to_slot = to_slot_
  plan.count = count_
  function plan.dump(self, marker)
    print(marker.."Move "..self.count.." from "..self.from_slot.." to "..self.to_slot)
  end
  function plan.rebuild(self, recursive)
    if recursive then self.parent:rebuild(true) end
    self.model:reset(self.parent.model)
  end
  function plan.enact(self)
    robot.select(self.from_slot)
    assert(robot.transferTo(self.to_slot, self.count))
    return true
  end
end

local function setup_drop(plan, item_slot_, location_, name_, count_)
  assert(item_slot_ and location_ and name_ and count_)
  plan.type = "drop"
  plan.item_slot = item_slot_
  plan.location = location_
  plan.name = name_
  plan.count = count_
  function plan.dump(self, marker)
    print(marker.."Drop "..self.count.." "..self.name.." from "..self.item_slot.." at "..self.location)
  end
  function plan.rebuild(self, recursive)
    if recursive then self.parent:rebuild(true) end
    self.model:reset(self.parent.model)
  end
  function plan.enact(self)
    libplace.go_to(self.location)
    local ico = component.inventory_controller
    local oldslot = ico.getStackInInternalSlot(self.item_slot)
    local oldslot_size = 0
    if oldslot then oldslot_size = oldslot.size end
    
    robot.select(self.item_slot)
    assert(robot.dropDown(self.count))
    
    local newslot = ico.getStackInInternalSlot(self.item_slot)
    local newslot_size = 0
    if newslot then newslot_size = newslot.size end
    
    assert(newslot_size == oldslot_size - self.count)
    
    return true
  end
end

local function setup_suck(plan, item_slot_, location_, name_, count_)
  plan.type = "suck"
  plan.item_slot = item_slot_
  plan.location = location_
  plan.name = name_
  plan.count = count_
  function plan.dump(self, marker)
    print(marker.."Suck "..self.count.." "..self.name.." to "..self.item_slot.." at "..self.location)
  end
  function plan.rebuild(self, recursive)
    if recursive then self.parent:rebuild(true) end
    self.model:reset(self.parent.model)
  end
  function plan.enact(self)
    if not self.count then return true end
    
    libplace.go_to(self.location)
    local ico = component.inventory_controller
    local oldslot = ico.getStackInInternalSlot(self.item_slot)
    local oldslot_size = 0
    if oldslot then oldslot_size = oldslot.size end
    
    robot.select(self.item_slot)
    
    local remaining = self.count
    
    while remaining > 0 do 
      robot.suck(remaining)
      
      local newslot = ico.getStackInInternalSlot(self.item_slot)
      local newslot_size = 0
      if newslot then newslot_size = newslot.size end
      
      local items_gained = newslot_size - oldslot_size
      assert(items_gained <= self.count)
      
      remaining = self.count - items_gained
    end
    
    return true
  end
end

function libplan.action_fetch(plan, item_slot, name, count, capacity)
  assert(name and count and capacity)
  assert(count <= capacity)
  local newplan = libplan.plan_create(plan)
  local avail = newplan.model:get_item_count(name)
  if avail >= count then
    setup_fetch(newplan, item_slot, name, count, capacity)
    newplan:rebuild(false)
    return newplan
  end
  return nil,"not enough items found fetching "..count.." "..name
end

-- return new plan or nil,error if failed
-- capacity override so damaged items can be stored as stack=1
function libplan.action_store(plan, item_slot, name, count, capacity)
  assert(name and count and capacity)
  -- search through chests for a slot containing the item and not full
  -- if found, store as many items as fit
  -- if items left over, store in a free slot
  local newplan = libplan.plan_create(plan)
  setup_store(newplan, item_slot, name, count, capacity)
  newplan:rebuild(false)
  return newplan
end

-- rather trivial, since it has little logic of its own because its items are assumed to be provided by fetch actions
function libplan.action_craft(plan, slot, name, count)
  local newplan = libplan.plan_create(plan)
  setup_craft(newplan, slot, name, count)
  newplan:rebuild(false)
  return newplan
end

function libplan.action_drop(plan, direction, slot, location, name, count)
  assert(direction == "down")
  assert(slot and location and name and count)
  local newplan = libplan.plan_create(plan)
  setup_drop(newplan, slot, location, name, count)
  newplan:rebuild(false)
  return newplan
end

function libplan.action_suck(plan, slot, location, name, count)
  local newplan = libplan.plan_create(plan)
  setup_suck(newplan, slot, location, name, count)
  newplan:rebuild(false)
  return newplan
end

function libplan.plan_to_list(plan)
  -- invert order
  local list = nil
  while plan do
    list = {plan = plan, next = list}
    plan = plan.parent
  end
  return list
end

function libplan.dump_list(list, focus)
  local i = 0
  while list do
    if not focus or (i > focus - 7 and i < focus + 7) then
      if i == focus then
        list.plan:dump(i.."> ")
      else
        list.plan:dump(i..": ")
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

-- optimizes just the current step of the plan!
function libplan.opt1(plan)
  if plan.type == "move" then
    if plan.parent.type == "fetch" and plan.parent.item_slot == plan.from_slot and plan.parent.count == plan.count then
      plan.parent.item_slot = plan.to_slot
      return plan.parent
    end
    if plan.parent.type == "craft" and plan.parent.item_slot == plan.from_slot and plan.parent.count == plan.count then
      plan.parent.item_slot = plan.to_slot
      return plan.parent
    end
  end
  if plan.type == "fetch" then
    -- try to find a matching store parent
    local match = plan.parent
    local pred = plan
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
          
          -- matches us, cut match out
          local new_plan
          if items_still_stored == 0 then
            new_plan = match.parent
          else
            new_plan = match
            match.count = items_still_stored
          end
          if not (plan.item_slot == match.item_slot) then
            new_plan = libplan.plan_create(new_plan)
            setup_move(new_plan, match.item_slot, plan.item_slot, plan.count)
            new_plan = libplan.opt1(new_plan)
          end
          pred.parent = new_plan
          
          local res
          if items_still_fetched == 0 then
            res = plan.parent
          else
            plan.count = items_still_fetched
            res = plan
          end
          res:rebuild(true)
          return libplan.opt1(res)
        end
        if plan.item_slot == match.item_slot then
          -- slot collision
          break
        end
      end
      pred = match
      match = match.parent
    end
  end
  return plan
end

function libplan.enact(plan)
  print("Enact.")
  local full_list = libplan.plan_to_list(plan)
  local list = full_list
  local i = 1
  while list do
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
