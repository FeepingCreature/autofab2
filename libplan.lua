local libchest = require("libchest")
local libplace = require("libplace")
local libcapacity = require("libcapacity")
local component = require("component")
local sides = require("sides")
local robot = require("robot")
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
  return obj.items[name] or 0
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
  
  assert(newslot_size == self.count)
  return true
end

local occupy = {}
libplan.occupy = occupy

for k,v in pairs(libplan.plan) do occupy[k] = v end
occupy.mt = { __index = occupy }

function occupy.new(self, parent, slot, count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "occupy"
  obj.slot = slot
  obj.count = count
  obj:rebuild()
  return obj
end

function occupy.dump(self, marker)
  if self.count == 0 then
    print(marker.."Slot "..self.slot.." not occupied")
  else
    print(marker.."Slot "..self.slot.." occupied by "..self.count)
  end
end

function occupy.rebuild(self, depth)
  if depth and depth > 1 then self.parent:rebuild(depth - 1) end
  self:reset()
end

function occupy.enact(self)
  assert(false)
end

local move = {}
libplan.move = move

for k,v in pairs(libplan.plan) do move[k] = v end
move.mt = { __index = move }

function move.new(self, parent, from_slot, to_slot, count)
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

function drop.new(self, parent, item_slot, location, name, count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "drop"
  obj.item_slot = item_slot
  obj.location = location
  obj.name = name
  obj.count = count
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

local suck = {}
libplan.suck = suck

for k,v in pairs(libplan.plan) do suck[k] = v end
suck.mt = { __index = suck }

function suck.new(self, parent, item_slot, location, name, count)
  local obj = libplan.plan.new(self, parent)
  obj.type = "suck"
  obj.item_slot = item_slot
  obj.location = location
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

function libplan.action_fetch(plan, item_slot, name, count, capacity)
  assert(name and count and capacity)
  assert(count <= capacity)
  local avail = plan:get_item_count(name)
  if avail >= count then
    return libplan.fetch:new(plan, item_slot, name, count, capacity)
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
  return libplan.store:new(plan, item_slot, name, count, capacity)
end

-- rather trivial, since it has little logic of its own because its items are assumed to be provided by fetch actions
function libplan.action_craft(plan, slot, name, count)
  return libplan.craft:new(plan, slot, name, count)
end

function libplan.action_occupy(plan, slot, count)
  return libplan.occupy:new(plan, slot, count)
end

function libplan.action_drop(plan, direction, slot, location, name, count)
  assert(direction == "down")
  assert(slot and location and name and count)
  return libplan.drop:new(plan, slot, location, name, count)
end

function libplan.action_suck(plan, slot, location, name, count)
  return libplan.suck:new(plan, slot, location, name, count)
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
    if not focus or (i > focus - 7 and i < focus + 7) then
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

libplan.final_opt = false

-- optimizes just the current step of the plan!
function libplan.opt1(plan)
  if plan.type == "occupy" and plan.parent and plan.parent.parent then
    local match1 = plan.parent.parent
    local match2 = plan.parent
    if match1.type == "fetch" and match2.type == "drop"
      and match1.item_slot == match2.item_slot
      and match1.count == match2.count
      and in_craft_grid(match1.item_slot)
      and plan.count == 0
    then
      match1.item_slot = plan.slot
      match2.item_slot = plan.slot
      plan.parent = match1.parent
      plan:rebuild()
      match1.parent = libplan.opt1(plan)
      match2:rebuild(2)
      return match2
    end
  end
  
  if plan.type == "occupy" then
    if not plan.parent.parent then return plan.parent end
    local active = plan.parent
    local before = plan.parent.parent
    if active.type == "move" then
      if plan.slot == active.from_slot then
        plan.count = plan.count + active.count
      end
    -- lose items in slot
    elseif active.type == "store" or active.type == "drop" then
      if plan.slot == active.item_slot then
        plan.count = plan.count + active.count -- inverse
      end
    -- gain items in slot
    elseif active.type == "craft" or active.type == "fetch" or active.type == "suck" then
      if plan.slot == active.item_slot then
        plan.count = plan.count - active.count -- inverse
        assert(plan.count >= 0)
      end
    else
      assert(false, "unknown occupy type "..active.type)
    end
    plan.parent = before
    plan:rebuild()
    active.parent = libplan.opt1(plan)
    active:rebuild()
    return active
  end
  
  -- rewrite craft ops into slot 8
  if libplan.final_opt and plan.parent
  then
    local cr = plan.parent
    local st = plan
    if cr.type == "craft" and st.type == "store"
      and cr.item_slot == st.item_slot
      and cr.count == st.count
      and in_craft_grid(cr.item_slot)
    then
      cr.item_slot = 8
      st.item_slot = 8
      return libplan.opt1(plan)
    end
  end
  
  -- combine 2-craft ops
  -- TODO generate the recipes in bulk to begin with
  if plan.parent and plan.parent.parent and plan.parent.parent.parent
    and plan.parent.parent.parent.parent
    and plan.parent.parent.parent.parent.parent
    and plan.parent.parent.parent.parent.parent.parent
    and plan.parent.parent.parent.parent.parent.parent.parent
  then
    local fe1a = plan.parent.parent.parent.parent.parent.parent.parent
    local fe1b = plan.parent.parent.parent.parent.parent.parent
    local cr1  = plan.parent.parent.parent.parent.parent
    local st1  = plan.parent.parent.parent.parent
    local fe2a = plan.parent.parent.parent
    local fe2b = plan.parent.parent
    local cr2  = plan.parent
    local st2  = plan
    if    fe1a.type == "fetch" and in_craft_grid(fe1a.item_slot)
      and fe1b.type == "fetch" and in_craft_grid(fe1b.item_slot)
      and cr1.type == "craft" and st1.type == "store"
      and st1.item_slot == cr1.item_slot and st1.count == cr1.count
      and fe2a.type == "fetch" and in_craft_grid(fe2a.item_slot)
      and fe2b.type == "fetch" and in_craft_grid(fe2b.item_slot)
      and cr2.type == "craft" and st2.type == "store"
      and st2.item_slot == cr2.item_slot and st2.count == cr2.count
      and cr1.item_slot == cr2.item_slot and not(in_craft_grid(cr1.item_slot))
      and fe1a.name == fe2a.name and fe1b.name == fe2b.name
      and fe1a.count + fe2a.count <= math.max(libcapacity.get_capacity(fe1a.name), libcapacity.get_capacity(fe2a.name))
      and fe1b.count + fe2b.count <= math.max(libcapacity.get_capacity(fe1b.name), libcapacity.get_capacity(fe2b.name))
      and cr1.count + cr2.count <= math.max(libcapacity.get_capacity(cr1.name), libcapacity.get_capacity(cr2.name))
    then
      fe2a.count = fe2a.count + fe1a.count
      fe2b.count = fe2b.count + fe1b.count
      cr2.count = cr2.count + cr1.count
      st2.count = st2.count + st1.count
      fe2a.parent = fe1a.parent
      plan:rebuild(5)
      return libplan.opt1(plan)
    end
  end
  
  -- merge machine ops
  if plan.parent and plan.parent.parent and plan.parent.parent.parent
    and plan.parent.parent.parent.parent and plan.parent.parent.parent.parent.parent
    and plan.parent.parent.parent.parent.parent.parent and plan.parent.parent.parent.parent.parent.parent.parent
  then
    -- fetch drop suck store
    local st2 = plan
    local su2 = plan.parent
    local dr2 = plan.parent.parent
    local fe2 = plan.parent.parent.parent
    local st1 = plan.parent.parent.parent.parent
    local su1 = plan.parent.parent.parent.parent.parent
    local dr1 = plan.parent.parent.parent.parent.parent.parent
    local fe1 = plan.parent.parent.parent.parent.parent.parent.parent
    if fe1.type == "fetch" and dr1.type == "drop" and su1.type == "suck" and st1.type == "store"
      and fe2.type == "fetch" and dr2.type == "drop" and su2.type == "suck" and st2.type == "store"
      and fe1.item_slot == dr1.item_slot and su1.item_slot == st1.item_slot
      and fe1.count == dr1.count and su1.count >= st1.count
      and same_machine(dr1.location, su1.location)
      and fe2.item_slot == dr2.item_slot and su2.item_slot == st2.item_slot
      and fe2.count == dr2.count and su2.count >= st2.count
      and same_machine(dr2.location, su2.location)
      and dr1.location == dr2.location
      -- and (fe1.name == fe2.name or st1.name == st2.name)
      and fe1.name == fe2.name
      and st1.item_slot == st2.item_slot
      and fe1.count + fe2.count <= math.max(libcapacity.get_capacity(fe1.name), libcapacity.get_capacity(fe2.name))
      and su1.count + su2.count <= math.max(libcapacity.get_capacity(st1.name), libcapacity.get_capacity(st2.name))
      and st1.count + st2.count <= math.max(libcapacity.get_capacity(st1.name), libcapacity.get_capacity(st2.name))
    then
      fe2.count = fe2.count + fe1.count
      dr2.count = dr2.count + dr1.count
      su2.count = su2.count + su1.count
      st2.count = st2.count + st1.count
      fe2.parent = fe1.parent
      plan:rebuild(5)
      return libplan.opt1(plan)
    end
  end
  
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
      plan, error = libplan.action_suck(plan.parent, plan.to_slot, plan.parent.location, plan.parent.name, plan.count)
      assert(plan, error)
      return libplan.opt1(plan)
    end
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
    elseif libplan.final_opt then
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
    and not(plan.parentfrom_slot == plan.item_slot or plan.parent.to_slot == plan.item_slot)
  then
    local fetch = plan
    local move = plan.parent
    fetch.parent = move.parent
    fetch:rebuild()
    move.parent = libplan.opt1(fetch)
    local new_plan = move
    new_plan:rebuild()
    return libplan.opt1(new_plan)
  end
  
  -- search if this item was dumped via an alias
  if plan.type == "fetch" then
    local match = plan.parent
    local pred = plan
    local i = 1
    while match do
      local cmp_store = match
      local cmp_fetch = match.parent
      if cmp_fetch and cmp_store and cmp_fetch.type == "fetch" and cmp_store.type == "store"
        and cmp_fetch.item_slot == cmp_store.item_slot
        and cmp_store.name == plan.name
        and cmp_fetch.count >= plan.count
        and cmp_store.count >= plan.count
      then
        local replace = math.min(plan.count, math.min(cmp_fetch.count, cmp_store.count))
        local items_still_fetched = math.max(0, cmp_fetch.count - replace)
        local items_still_stored = math.max(0, cmp_store.count - replace)
        local items_still_fetched_plan = math.max(0, plan.count - replace)
        local discard_fetch = items_still_fetched == 0
        local discard_store = items_still_stored == 0
        local discard_plan = items_still_fetched_plan == 0
        if discard_fetch then
          cmp_store.parent = cmp_fetch.parent
        else
          cmp_fetch.count = cmp_fetch.count - replace
        end
        if discard_store then
          pred.parent = cmp_store.parent
        else
          cmp_store.count = cmp_store.count - replace
        end
        local newplan
        if discard_plan then
          newplan = plan.parent
        else
          plan.count = plan.count - replace
          newplan = plan
        end
        newplan:rebuild(i + 2)
        newplan = libplan.opt1(newplan)
        newplan = libplan.action_fetch(newplan, plan.item_slot, cmp_fetch.name, replace, libcapacity.get_capacity(cmp_fetch.name))
        return libplan.opt1(newplan)
      end
      pred = match
      match = match.parent
      i = i + 1
    end
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
          
          -- matches us, cut match out
          local new_plan
          if items_still_stored == 0 then
            new_plan = match.parent
          else
            new_plan = match
            match.count = items_still_stored
          end
          if not (plan.item_slot == match.item_slot) then
            new_plan = libplan.move:new(new_plan, match.item_slot, plan.item_slot, math.min(plan.count, match.count))
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
  
  local function swap(plan)
    local a, b = plan.parent, plan
    b.parent = a.parent
    b:rebuild()
    a.parent = libplan.opt1(b)
    a:rebuild()
    return libplan.opt1(a)
  end
  
  -- move sucks back beyond fetchs (always safe)
  if libplan.final_opt and plan.parent
    and plan.parent.type == "suck" and plan.type == "fetch"
  then
    return swap(plan)
  end
  
  -- start machines as early as possible
  if libplan.final_opt and plan.parent
    and plan.parent.type == "store" and plan.type == "drop"
  then
    return swap(plan)
  end
  
  -- start machines as early as possible
  if libplan.final_opt and plan.parent
    and plan.parent.type == "suck" and plan.type == "drop"
    and not (plan.parent.item_slot == plan.item_slot)
    and not same_machine(plan.parent.location, plan.location)
  then
    return swap(plan)
  end
  
  -- start machines as early as possible
  if libplan.final_opt and plan.parent
    and plan.parent.type == "move" and plan.type == "drop"
    -- from slot is okay, since we'll still have it after the drop
    and not (plan.parent.to_slot == plan.item_slot)
  then
    return swap(plan)
  end
  
  -- start machines as early as possible
  if libplan.final_opt and plan.parent and plan.parent.parent then
    local action = plan.parent.parent
    local fetch = plan.parent
    local drop = plan
    if fetch.type == "fetch" and drop.type == "drop"
      and fetch.count == drop.count and fetch.item_slot == drop.item_slot
    then
      local function move_past()
        fetch.parent = action.parent
        fetch:rebuild()
        drop.parent = libplan.opt1(fetch)
        drop:rebuild()
        action.parent = libplan.opt1(drop)
        action:rebuild()
        return action
      end
      
      if action.type == "store" and not(action.item_slot == fetch.item_slot) then
        if not (action.name == fetch.name) then
          return move_past()
        end
      elseif action.type == "fetch" then
        if not (action.item_slot == fetch.item_slot) then
          return move_past()
        end
      elseif action.type == "craft" then
        if not(action.item_slot == fetch.item_slot) then
          return move_past()
        end
      elseif action.type == "move" then
        if not(action.from_slot == fetch.item_slot or action.to_slot == fetch.item_slot) then
          return move_past()
        end
      elseif action.type == "suck" and not(action.item_slot == fetch.item_slot) then
        if not same_machine(action.location, drop.location) then
          return move_past()
        end
      else
        -- print("can I move fetchdrop 4 past?")
        -- action:dump("#")
      end
    end
  end
  
  return plan
end

function libplan.opt(plan)
  if not plan.parent then return plan end
  plan.parent = libplan.opt(plan.parent)
  plan.parent:rebuild()
  return libplan.opt1(plan)
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
