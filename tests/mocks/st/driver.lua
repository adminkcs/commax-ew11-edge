-- Minimal stand-in for st.driver, so init.lua can be required offline to
-- test its lifecycle handlers (device_init/device_info_changed/
-- device_removed) without the real SmartThings Lua runtime or a live Hub.
-- Only implements what init.lua actually calls on the driver instance:
-- call_on_schedule (recorded, not actually scheduled), call_with_delay
-- (no-op - the real EW11 coroutines must NOT actually start during a test),
-- get_devices/try_create_device (in-memory), and run (no-op, since the real
-- one blocks forever).
--
-- NOTE: this mock's Driver(name, template) simply uses `template` itself as
-- the returned instance (matching the actual Driver constructor's known
-- behavior of merging the given template's fields onto the instance it
-- returns) - it does NOT pull in any methods from other, separately-named
-- local tables in init.lua. If init.lua ever defines driver-only methods on
-- a table that isn't the literal template passed to Driver(...), those
-- methods will be missing here exactly as they would be on a real driver
-- instance too.
local last_instance = nil

local function new_driver(name, template)
  local instance = template or {}
  instance.name = name
  instance._scheduled = {}
  instance._devices = {}

  function instance:call_on_schedule(interval, fn, sched_name)
    table.insert(self._scheduled, { interval = interval, fn = fn, name = sched_name })
  end

  function instance:call_with_delay(delay, fn)
    -- Intentionally does NOT invoke fn: the real EW11:start() schedules its
    -- connection/tx-queue coroutines this way, and a lifecycle test must not
    -- actually open a socket or spin a background loop.
    self._delayed = self._delayed or {}
    table.insert(self._delayed, { delay = delay, fn = fn })
  end

  function instance:get_devices()
    return self._devices
  end

  function instance:try_create_device(spec)
    table.insert(self._devices, spec)
  end

  function instance:run() end

  last_instance = instance
  return instance
end

local M = setmetatable({}, {
  __call = function(_, name, template) return new_driver(name, template) end
})

function M._get_last_instance()
  return last_instance
end

return M
