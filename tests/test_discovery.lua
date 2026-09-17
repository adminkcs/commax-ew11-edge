-- =========================================================================
-- Driver Discovery Unit Tests (src/init.lua)
--
-- Verifies that:
-- 1. driver.discovery handler exists and can be called without runtime errors.
-- 2. Discovery creates the root bridge device with type="LAN" and dni="commax-bridge".
-- 3. Repeated discovery does not create duplicate bridge devices.
-- 4. get_device_by_dni correctly finds existing devices.
-- =========================================================================
package.path = "mocks/?.lua;mocks/?/init.lua;../src/?.lua;" .. package.path

require("init")
local st_driver_mock = require("st.driver")
local driver = st_driver_mock._get_last_instance()

assert(driver ~= nil, "init.lua must construct a driver instance")
assert(type(driver.discovery) == "function", "driver.discovery handler must be registered")
assert(type(driver.get_device_by_dni) == "function", "driver:get_device_by_dni method must be available")
assert(type(driver.sync_child_devices) == "function", "driver:sync_child_devices method must be available")
assert(type(driver.poll_all_devices) == "function", "driver:poll_all_devices method must be available")

print("=== Starting Driver Discovery Tests ===")

-- 1. First discovery call: should create the bridge device
assert(#driver:get_devices() == 0, "Initial device list should be empty")
driver.discovery(driver, {}, function() return true end)
assert(#driver:get_devices() == 1, "Discovery must create exactly 1 bridge device on first run")

local bridge = driver:get_device_by_dni("commax-bridge")
assert(bridge ~= nil, "Bridge device must be retrievable by DNI 'commax-bridge'")
assert(bridge.type == "LAN", "Bridge device type must be 'LAN'")
assert(bridge.profile == "commax-bridge", "Bridge device profile must be 'commax-bridge'")
assert(bridge.label == "코맥스 월패드 브릿지", "Bridge label must match expected string")
print("[PASS] discovery: creates root LAN bridge device")

-- 2. Repeated discovery call: should NOT create duplicate bridge
driver.discovery(driver, {}, function() return true end)
assert(#driver:get_devices() == 1, "Repeated discovery must not create duplicate bridge device")
print("[PASS] discovery: idempotent (no duplicate bridge created)")

-- 3. Device lookup by parent_assigned_child_key
table.insert(driver._devices, {
  type = "EDGE_CHILD",
  parent_assigned_child_key = "commax:light:99",
  label = "테스트 조명"
})
local child = driver:get_device_by_dni("commax:light:99")
assert(child ~= nil, "get_device_by_dni must support finding device by parent_assigned_child_key")
print("[PASS] get_device_by_dni: supports parent_assigned_child_key")

print("=== All Discovery Tests Passed Successfully! ===")
