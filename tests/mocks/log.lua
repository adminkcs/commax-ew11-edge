-- Minimal stand-in for the SmartThings Edge Driver `log` global module, so
-- ew11.lua can be required and unit-tested offline without the real
-- SmartThings Lua runtime. Captures nothing; just no-ops so calls don't crash.
local log = {}
function log.debug(msg) end
function log.info(msg) end
function log.warn(msg) end
function log.error(msg) end
return log
