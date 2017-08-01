local libnav = require("libnav")
local util = require("util")

util.init()

local args = { ... }
local movestr = args[1] or ""
libnav.add(movestr)
libnav.flush()
