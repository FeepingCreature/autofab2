local util = require("util")
local libnav = require("libnav")

local config_file = "places.cfg"

local libplace = {
}

function libplace.get_cost(name)
  local place = util.config_get(config_file, name)
  if not place then return nil end
  libnav.return_to(place)
  return libnav.estimate_and_discard()
end

function libplace.save_as(name)
  util.config_set(config_file, name, libnav.get_location())
end

function libplace.go_to(name)
  assert(name)
  local place = util.config_get(config_file, name)
  assert(place, "no such place: '"..name.."'!")
  libnav.go_to(place)
  libnav.flush()
end

return libplace
