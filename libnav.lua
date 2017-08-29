local util = require("util")
local robot = require("robot")

local config_file = "state.cfg"

local libnav = {
  str = "",
  _navlog = "",
  retry = true
}

function libnav.get_location()
  return util.config_get(config_file, "location", "")
end

local function log_flush()
  local state = util.config(config_file)
  local place = state:get("location", "")
  place = place .. libnav._navlog
  libnav._navlog = ""
  state:set("location", place)
  state:close()
end

local function log_assert(cond)
  if not cond then log_flush() end
  assert(cond)
end

local function record(str)
  libnav._navlog = libnav._navlog .. str
end

function retry_loop(fn, msg)
  while true do
    if fn() then break end
    if libnav.retry then os.sleep(1) else log_assert(false, msg) end
  end
end

local function _up()
  retry_loop(robot.up, "can't move up")
  record("u")
end
local function _down()
  retry_loop(robot.down, "can't move down")
  record("d")
end
local function _turnLeft()
  retry_loop(robot.turnLeft, "can't turn left")
  record("l")
end
local function _turnRight()
  retry_loop(robot.turnRight, "can't turn right")
  record("r")
end
local function _forward()
  retry_loop(robot.forward, "can't move forward")
  record("f")
end
local function _back()
  retry_loop(robot.back, "can't move back")
  record("b")
end

function libnav.add(str)
  libnav.str = libnav.str .. str
end

function libnav.up() libnav.add("u")
end
function libnav.down() libnav.add("d")
end
function libnav.left() libnav.add("l")
end
function libnav.right() libnav.add("r")
end
function libnav.fwd() libnav.add("f")
end
function libnav.back() libnav.add("b")
end

function libnav.opt(str)
  -- todo optimize
  local bak = str
  while true do
    local prev = str
    str = str
      :gsub("ud", ""):gsub("du", "")
      :gsub("fb", ""):gsub("bf", "")
      :gsub("rl", ""):gsub("lr", "")
      :gsub("llll", ""):gsub("rrrr", "")
      :gsub("fllf", "ll"):gsub("frrf", "rr")
      :gsub("bllb", "ll"):gsub("brrb", "rr")
      :gsub("dllu", "ll"):gsub("drru", "rr")
      :gsub("ulld", "ll"):gsub("urrd", "rr")
      :gsub("dlu", "l"):gsub("dru", "r")
      :gsub("uld", "l"):gsub("urd", "r")
      :gsub("dfu", "f"):gsub("dbu", "b")
      :gsub("ufd", "f"):gsub("ubd", "b")
      :gsub("lll", "r"):gsub("rrr", "l")
      -- move all rotations down so they can cancel
      :gsub("ul", "lu"):gsub("ur", "ru")
      :gsub("ld", "dl"):gsub("rd", "dr")
			:gsub("frfrf", "rfr"):gsub("flflf", "lfl")
			:gsub("frflb", "rfl"):gsub("flfrb", "lfr")
    if prev == str then break end
  end
  return str;
end

function libnav.flush()
  local actions = {
    u = _up,
    d = _down,
    l = _turnLeft,
    r = _turnRight,
    f = _forward,
    b = _back
  }
  local str = libnav.opt(libnav.str)
  libnav.str = ""
  for i = 1, str:len() do
    local ch = str:sub(i, i)
    local action = actions[ch]
    assert(action)
    action()
  end
  log_flush()
  -- optimize place
  local state = util.config(config_file)
  local place = state:get("location", "")
  place = libnav.opt(place)
  state:set("location", place)
  state:close()
end

function libnav.estimate_and_discard()
  local str = libnav.opt(libnav.str)
  libnav.str = ""
  return str:len()
end

function libnav.invert(movestr)
  local res = ""
  local flips = {
    u = "d",
    d = "u",
    l = "r",
    r = "l",
    f = "f",
    b = "b"
  }
  for i = movestr:len(), 1, -1 do
    local ch = movestr:sub(i, i)
    local flip = flips[ch]
    assert(flip)
    res = res .. flip
  end
  return "rr" .. res .. "rr"
end

-- go to where 'libnav.get_location()' was 'loc'
function libnav.go_to(loc)
  libnav.add(libnav.invert(libnav.get_location()))
  libnav.add(loc)
end

return libnav
