local EW11 = require("ew11")
local handler = require("device_handler")
local protocol = require("commax_protocol")

print("=== Starting Preferences Expansion Unit Tests ===")

-- 1. Test EW11 dynamic timing config & ms-to-sec conversion
local fake_driver = {
  call_with_delay = function(self, delay, cb) end,
  get_devices = function(self) return {} end,
  get_device_by_dni = function(self, dni) return nil end,
}

local ew11_inst = EW11.new(fake_driver, "192.168.50.243", 8899, nil, {
  tx_retry_cnt = 4,
  tx_delay_ms = 25,
  rx_timeout_ms = 15,
  ack_timeout_ms = 350,
})

assert(ew11_inst.ip == "192.168.50.243", "IP should match")
assert(ew11_inst.port == 8899, "Port should match")
assert(ew11_inst.tx_retry_cnt == 4, "tx_retry_cnt should be 4")
assert(math.abs(ew11_inst.tx_delay - 0.025) < 1e-6, "tx_delay should be 0.025s (25ms)")
assert(math.abs(ew11_inst.rx_timeout - 0.015) < 1e-6, "rx_timeout should be 0.015s (15ms)")
assert(math.abs(ew11_inst.tx_timeout - 0.350) < 1e-6, "tx_timeout should be 0.350s (350ms)")
print("[PASS] EW11 initial config ms-to-sec conversion")

-- 2. Test EW11:update_config dynamic changes
ew11_inst:update_config("192.168.50.244", 8898, {
  tx_retry_cnt = 2,
  tx_delay_ms = 50,
  rx_timeout_ms = 30,
  ack_timeout_ms = 500,
})

assert(ew11_inst.ip == "192.168.50.244", "Updated IP should match")
assert(ew11_inst.port == 8898, "Updated Port should match")
assert(ew11_inst.tx_retry_cnt == 2, "Updated tx_retry_cnt should be 2")
assert(math.abs(ew11_inst.tx_delay - 0.050) < 1e-6, "Updated tx_delay should be 0.050s")
assert(math.abs(ew11_inst.rx_timeout - 0.030) < 1e-6, "Updated rx_timeout should be 0.030s")
assert(math.abs(ew11_inst.tx_timeout - 0.500) < 1e-6, "Updated tx_timeout should be 0.500s")
print("[PASS] EW11 update_config dynamic update")

-- 3. Test elevator call repeat count preference
local enqueued = {}
ew11_inst.send = function(self, pkt, ack, opts)
  table.insert(enqueued, { pkt = pkt, ack = ack, opts = opts })
end
fake_driver.ew11 = ew11_inst

local bridge_mock = {
  id = "bridge-1",
  device_network_id = "commax-bridge",
  preferences = {
    elevatorCallCount = 3,
  }
}
fake_driver.get_device_by_dni = function(self, dni)
  if dni == "commax-bridge" then return bridge_mock end
  return nil
end

handler.handle_elevator_call_down(fake_driver, { device_network_id = "commax:elevator:1" }, {})
assert(#enqueued == 1, string.format("Expected 1 atomic burst job enqueued, got %d", #enqueued))
assert(enqueued[1].opts and enqueued[1].opts.burst_count == 3, string.format("Expected burst_count 3, got %s", tostring(enqueued[1].opts and enqueued[1].opts.burst_count)))
assert(enqueued[1].opts and enqueued[1].opts.burst_delay == 0.015, "Expected burst_delay 0.015s")
assert(enqueued[1].opts and enqueued[1].opts.tag == "elevator", "Expected tag 'elevator'")
print("[PASS] Elevator call repeat count (atomic 3-packet burst)")

-- 4. Test Child Device sync with enable flags via init.lua driver
require("init")
local st_driver_mock = require("st.driver")
local driver = st_driver_mock._get_last_instance()

local created_devices = {}
driver.try_create_device = function(self, spec)
  table.insert(created_devices, spec)
  table.insert(self._devices, {
    id = "dev-" .. tostring(#self._devices + 1),
    device_network_id = spec.device_network_id,
    label = spec.label,
    parent_device_id = spec.parent_device_id
  })
  return true
end

-- Reset device list
driver._devices = {}

local test_bridge = {
  id = "bridge-test",
  device_network_id = "commax-bridge",
  preferences = {
    enableLight = false,
    lightCount = 4,
    enableHeating = true,
    heaterCount = 2,
    enableOutlet = false,
    enableFan = false,
    enableGas = true,
    enableAirQuality = false,
    enableElevator = true,
  }
}

driver:sync_child_devices(test_bridge)

local light_created = 0
local heater_created = 0
local outlet_created = 0
local gas_created = 0
local elevator_created = 0

for _, dev in ipairs(created_devices) do
  if dev.device_network_id:match("^commax:light:") then light_created = light_created + 1 end
  if dev.device_network_id:match("^commax:thermostat:") then heater_created = heater_created + 1 end
  if dev.device_network_id:match("^commax:outlet:") then outlet_created = outlet_created + 1 end
  if dev.device_network_id == "commax:gas:1" then gas_created = gas_created + 1 end
  if dev.device_network_id == "commax:elevator:1" then elevator_created = elevator_created + 1 end
end

assert(light_created == 0, "No lights should be created when enableLight=false")
assert(heater_created == 2, "2 heaters should be created")
assert(outlet_created == 0, "No outlets should be created when enableOutlet=false")
assert(gas_created == 1, "Gas valve should be created")
assert(elevator_created == 1, "Elevator should be created")
print("[PASS] sync_child_devices respects enable/disable flags and counts")

-- 5. Test Default Preferences: No child devices created when preferences are empty or default (all false/0)
local default_created_devices = {}
driver.try_create_device = function(self, spec)
  table.insert(default_created_devices, spec)
  return true
end
driver._devices = {}

local default_bridge = {
  id = "bridge-default",
  device_network_id = "commax-bridge",
  preferences = {}
}

driver:sync_child_devices(default_bridge)
assert(#default_created_devices == 0, string.format("Expected 0 devices created by default, but got %d", #default_created_devices))
print("[PASS] sync_child_devices creates NO devices by default (empty preferences)")

-- Also test with explicit default-profile values (all false, counts 0)
default_created_devices = {}
local explicit_default_bridge = {
  id = "bridge-explicit-default",
  device_network_id = "commax-bridge",
  preferences = {
    enableLight = false,
    lightCount = 0,
    enableHeating = false,
    heaterCount = 0,
    enableOutlet = false,
    outletCount = 0,
    enableFan = false,
    enableGas = false,
    enableAirQuality = false,
    enableElevator = false,
  }
}

driver:sync_child_devices(explicit_default_bridge)
assert(#default_created_devices == 0, string.format("Expected 0 devices created with explicit default false/0, but got %d", #default_created_devices))
print("[PASS] sync_child_devices creates NO devices with explicit profile defaults (all false, count 0)")

print("=== All Preferences Expansion Tests Passed Successfully! ===")
