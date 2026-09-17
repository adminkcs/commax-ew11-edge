-- =========================================================================
-- Driver Lifecycle Regression Suite (src/init.lua)
--
-- Added per QA review follow-up (A-1): verifies that driver._heater_poll_
-- scheduled is reset when the bridge device is removed, so that a later
-- bridge re-add (discovery after removal, still within the same driver
-- process) can register the heater polling schedule again. Without the
-- fix, device_init's "not driver._heater_poll_scheduled" guard would stay
-- permanently false-true (i.e. "already scheduled") after the bridge that
-- originally set it is gone, silently disabling heater polling forever
-- until the whole driver process restarts.
--
-- Requires init.lua for real (not a reimplementation of its logic), using
-- offline mocks for st.driver/st.capabilities/log/cosock.socket so it can
-- run without the real SmartThings Lua runtime or a live Hub/EW11.
-- =========================================================================
package.path = "mocks/?.lua;mocks/?/init.lua;" .. package.path

require("init") -- runs init.lua's module body, including Driver(...) construction
local st_driver_mock = require("st.driver")
local driver = st_driver_mock._get_last_instance()
assert(driver ~= nil, "init.lua must construct a driver instance via Driver(...)")
assert(driver.lifecycle_handlers and driver.lifecycle_handlers.init
  and driver.lifecycle_handlers.infoChanged and driver.lifecycle_handlers.removed,
  "init.lua must register init/infoChanged/removed lifecycle handlers")

local function make_bridge_device(prefs)
  return {
    label = "코맥스 월패드 브릿지",
    device_network_id = "commax-bridge",
    preferences = prefs or {},
  }
end

print("=== Starting Driver Lifecycle Tests ===")

-- 1. Normal init: with valid EW11 prefs and a positive pollInterval, the
-- heater polling schedule must be registered exactly once.
do
  local bridge = make_bridge_device({ ew11Ip = "192.168.50.243", ew11Port = 8899, pollInterval = 10 })
  driver.lifecycle_handlers.init(driver, bridge)
  assert(driver._heater_poll_scheduled == true, "Heater polling schedule flag must be set after init")
  assert(#driver._scheduled == 1, "Heater polling schedule must be registered exactly once on first init")
  assert(driver.ew11 ~= nil, "driver.ew11 must be constructed for the bridge device")
  print("[PASS] device_init: heater polling scheduled once with valid preferences")
end

-- 2. Re-running device_init for the SAME still-present bridge (e.g. driver
-- restart, hub resync) must NOT double-schedule polling - this is the
-- existing guard the flag was designed for; must not regress.
do
  driver.lifecycle_handlers.init(driver, make_bridge_device({ ew11Ip = "192.168.50.243", ew11Port = 8899, pollInterval = 10 }))
  assert(#driver._scheduled == 1, "A repeated device_init call while the bridge still exists must not re-register the schedule")
  print("[PASS] device_init: repeated init (e.g. driver restart) does not double-schedule polling")
end

-- 3. Bridge removal: driver.ew11 must be torn down AND the heater poll
-- schedule flag must be reset, so a future re-add can schedule again. This
-- is the actual fix under test (src/init.lua device_removed).
do
  driver.lifecycle_handlers.removed(driver, make_bridge_device())
  assert(driver.ew11 == nil, "driver.ew11 must be cleared when the bridge device is removed")
  assert(driver._heater_poll_scheduled == false,
    "FIX A-1: _heater_poll_scheduled must be reset to false when the bridge is removed, " ..
    "so a later bridge re-add (same driver process) can schedule heater polling again")
  print("[PASS] device_removed: driver.ew11 cleared and heater poll schedule flag reset")
end

-- 4. Bridge re-created after removal (discovery finds no bridge, creates a
-- new one -> device_init runs again for it, same driver process): heater
-- polling must be able to register again. Before the A-1 fix, this would
-- fail silently (schedule flag stuck true from the removed bridge).
do
  driver.lifecycle_handlers.init(driver, make_bridge_device({ ew11Ip = "192.168.50.243", ew11Port = 8899, pollInterval = 10 }))
  assert(#driver._scheduled == 2,
    "After a bridge remove+recreate cycle, device_init must be able to register the heater " ..
    "polling schedule again (regression guard for the A-1 fix)")
  assert(driver._heater_poll_scheduled == true, "Flag must be set again after the new schedule registration")
  print("[PASS] device_init after remove+recreate: heater polling schedule can be registered again")
end

-- 5. Removing a non-bridge device must not touch driver.ew11 or the poll
-- schedule flag at all (device_removed must correctly scope its bridge-only
-- cleanup, not reset state on every device removal).
do
  driver._heater_poll_scheduled = true
  local ew11_marker = driver.ew11
  driver.lifecycle_handlers.removed(driver, { device_network_id = "commax:light:1", label = "테스트 조명" })
  assert(driver._heater_poll_scheduled == true, "Removing a non-bridge child device must not reset the heater poll flag")
  assert(driver.ew11 == ew11_marker, "Removing a non-bridge child device must not touch driver.ew11")
  print("[PASS] device_removed: removing a non-bridge device does not affect bridge-scoped state")
end

-- 6. Invalid EW11 preferences (e.g. empty IP) must not crash device_init,
-- and must not connect/schedule (existing validate_ew11_prefs behavior -
-- pinned here as a baseline, not changed by this task).
do
  local before_ew11 = driver.ew11
  local ok = pcall(function()
    driver.lifecycle_handlers.init(driver, make_bridge_device({ ew11Ip = "", ew11Port = 8899, pollInterval = 10 }))
  end)
  assert(ok, "device_init must not raise even with an invalid EW11 IP preference")
  print("[PASS] device_init: invalid EW11 preferences are handled without raising")
end

print("=== All Driver Lifecycle Tests Passed Successfully! ===")
