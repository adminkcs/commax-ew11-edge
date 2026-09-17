local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local log = require("log")
local EW11 = require("ew11")
local protocol = require("commax_protocol")
local handler = require("device_handler")

local commax_driver = {}

function commax_driver:get_device_by_dni(dni)
  for _, device in ipairs(self:get_devices()) do
    if device.device_network_id == dni then
      return device
    end
  end
  return nil
end

--- Create a single child device, isolated from failures in sibling
--- creations. If try_create_device throws (e.g. a transient cloud API
--- error) or returns an error, log and continue - one failed device must
--- not stop the remaining lights/heaters/fan/gas from being created.
local function safe_create_device(self, spec)
  local ok, err = pcall(function() self:try_create_device(spec) end)
  if not ok then
    log.error(string.format("[Init] Failed to create device %s: %s", spec.device_network_id, tostring(err)))
  end
end

--- Create Child Devices according to Bridge Preferences
function commax_driver:sync_child_devices(bridge_device)
  local prefs = bridge_device.preferences or {}

  -- Preferences come from user input in the SmartThings app - clamp to the
  -- profile's declared range rather than trusting them blindly (a stale or
  -- malformed value should not be able to create an unbounded number of
  -- devices or silently produce 0/negative loop bounds).
  local light_count = math.max(0, math.min(9, tonumber(prefs.lightCount) or 4))
  local heater_count = math.max(0, math.min(9, tonumber(prefs.heaterCount) or 4))
  local outlet_count = math.max(0, math.min(12, tonumber(prefs.outletCount) or 10))
  local enable_fan = (prefs.enableFan ~= false)
  local enable_gas = (prefs.enableGas ~= false)
  local enable_air_quality = (prefs.enableAirQuality ~= false)
  local enable_elevator = (prefs.enableElevator ~= false)

  -- 1. Create Lights
  -- Labels below are this home's real light 1-8 -> room/fixture mapping,
  -- confirmed 2026-09-17 by turning each one on individually and checking
  -- which physical light responded. Kept as "N 이름" (number first) so the
  -- SmartThings app tile still shows the underlying ID for easy re-editing
  -- if a different home reuses this driver.
  local LIGHT_LABELS = {
    "거실보조불", "거실불", "곰돌이불", "곰돌이보조불",
    "하트불", "별별이불", "주방불", "주방간접등",
  }
  for i = 1, light_count do
    local dni = string.format("commax:light:%d", i)
    if not self:get_device_by_dni(dni) then
      log.info(string.format("[Init] Creating child light device: %s", dni))
      local name = LIGHT_LABELS[i] or string.format("조명 %d", i)
      safe_create_device(self, {
        type = "EDGE_CHILD",
        label = string.format("%d %s", i, name),
        profile = "commax-light",
        parent_device_id = bridge_device.id,
        device_network_id = dni
      })
    end
  end

  -- 2. Create Thermostats
  -- Labels below are this home's real thermostat 1-4 -> room mapping,
  -- confirmed 2026-09-17 by setting each one to a distinct target
  -- temperature (21/22/23/24) and having the user check which room's
  -- wallpad showed which value (see LIGHT_LABELS above for the same
  -- method/rationale). ID 2 ("곰돌이난방") is the same physical room as
  -- "안방" referenced in earlier commax_protocol.lua comments/README
  -- sections - 안방 is this family's formal name for the room, 곰돌이 is
  -- the nickname used for its light/outlet/thermostat labels here.
  local THERMOSTAT_LABELS = {
    "거실난방", "곰돌이난방", "하트난방", "별별이난방",
  }
  for i = 1, heater_count do
    local dni = string.format("commax:thermostat:%d", i)
    if not self:get_device_by_dni(dni) then
      log.info(string.format("[Init] Creating child thermostat device: %s", dni))
      local name = THERMOSTAT_LABELS[i] or string.format("난방 %d", i)
      safe_create_device(self, {
        type = "EDGE_CHILD",
        label = string.format("%d %s", i, name),
        profile = "commax-thermostat",
        parent_device_id = bridge_device.id,
        device_network_id = dni
      })
    end
  end

  -- 3. Create Outlets
  -- Labels below are this home's real outlet 1-10 -> room/fixture mapping,
  -- confirmed 2026-09-17 by turning each one off individually and checking
  -- which physical outlet lost power (see LIGHT_LABELS above for the same
  -- method/rationale).
  local OUTLET_LABELS = {
    "거실커텐콘센트", "안방", "곰돌이창문콘센트", "곰돌이콘센트", "하트커텐콘센트",
    "하트콘센트", "별별이커텐콘센트", "별별이콘센트", "주방밥솥콘센트", "주방가스렌지콘센트",
  }
  for i = 1, outlet_count do
    local dni = string.format("commax:outlet:%d", i)
    if not self:get_device_by_dni(dni) then
      log.info(string.format("[Init] Creating child outlet device: %s", dni))
      local name = OUTLET_LABELS[i] or string.format("콘센트 %d", i)
      safe_create_device(self, {
        type = "EDGE_CHILD",
        label = string.format("%d %s", i, name),
        profile = "commax-outlet",
        parent_device_id = bridge_device.id,
        device_network_id = dni
      })
    end
  end

  -- 4. Create Fan
  if enable_fan then
    local dni = "commax:fan:1"
    if not self:get_device_by_dni(dni) then
      log.info("[Init] Creating child ventilation fan device")
      safe_create_device(self, {
        type = "EDGE_CHILD",
        label = "코맥스 환기팬",
        profile = "commax-fan",
        parent_device_id = bridge_device.id,
        device_network_id = dni
      })
    end
  end

  -- 5. Create Gas Valve
  if enable_gas then
    local dni = "commax:gas:1"
    if not self:get_device_by_dni(dni) then
      log.info("[Init] Creating child gas valve device")
      safe_create_device(self, {
        type = "EDGE_CHILD",
        label = "코맥스 가스밸브",
        profile = "commax-gas",
        parent_device_id = bridge_device.id,
        device_network_id = dni
      })
    end
  end

  -- 6. Create Air Quality Sensor (CO2/PM2.5/PM10, read-only)
  if enable_air_quality then
    local dni = "commax:airquality:1"
    if not self:get_device_by_dni(dni) then
      log.info("[Init] Creating child air quality sensor device")
      safe_create_device(self, {
        type = "EDGE_CHILD",
        label = "코맥스 공기질 센서",
        profile = "commax-airquality",
        parent_device_id = bridge_device.id,
        device_network_id = dni
      })
    end
  end

  -- 7. Create Elevator Down-Call button (momentary, no up-call/status)
  if enable_elevator then
    local dni = "commax:elevator:1"
    if not self:get_device_by_dni(dni) then
      log.info("[Init] Creating child elevator down-call device")
      safe_create_device(self, {
        type = "EDGE_CHILD",
        label = "코맥스 엘리베이터 하강호출",
        profile = "commax-elevator",
        parent_device_id = bridge_device.id,
        device_network_id = dni
      })
    end
  end
end

function commax_driver:poll_all_devices()
  if not self.ew11 then return end
  local bridge = self:get_device_by_dni("commax-bridge")
  local prefs = (bridge and bridge.preferences) or {}
  local heater_count = math.max(0, math.min(9, tonumber(prefs.heaterCount) or 4))

  -- Query heaters sequentially
  for i = 1, heater_count do
    self.ew11:send(protocol.build_thermostat_query(i))
  end
end

--- Validate EW11 connection preferences before acting on them. Preference
--- values come from free-form user input in the SmartThings app (or a
--- pre-existing device with a preference cleared/corrupted) - an empty IP,
--- non-numeric port, or out-of-range port must not be handed straight to
--- the socket layer, where they would just cause a silent/cryptic infinite
--- reconnect loop instead of a clear diagnostic.
local function validate_ew11_prefs(ip, port)
  if type(ip) ~= "string" or #ip == 0 then
    return nil, nil, "EW11 IP is empty or invalid"
  end
  local port_num = tonumber(port)
  if not port_num or port_num < 1 or port_num > 65535 then
    return nil, nil, string.format("EW11 port '%s' is invalid (must be 1-65535)", tostring(port))
  end
  return ip, math.floor(port_num), nil
end

-- =========================================================================
-- Driver Lifecycle Handlers
-- =========================================================================

local function device_init(driver, device)
  log.info(string.format("[Init] Device initialized: %s (DNI: %s)", device.label, device.device_network_id))

  if device.device_network_id == "commax-bridge" then
    local prefs = device.preferences or {}
    local ip, port, verr = validate_ew11_prefs(prefs.ew11Ip or "192.168.0.83", prefs.ew11Port or 8899)
    if verr then
      log.error(string.format("[Init] Invalid EW11 preferences (%s) - not (re)connecting until fixed in Settings", verr))
    else
      if not driver.ew11 then
        driver.ew11 = EW11.new(driver, ip, port, function(parsed)
          handler.handle_parsed_packet(driver, parsed)
        end)
        driver.ew11:start()
      else
        driver.ew11:update_config(ip, port)
      end
    end

    local ok, err = pcall(function() driver:sync_child_devices(device) end)
    if not ok then
      log.error(string.format("[Init] sync_child_devices failed: %s", tostring(err)))
    end

    -- Start periodic query schedule if enabled. device_init can legitimately
    -- fire more than once for the same device (e.g. driver restart, hub
    -- resync) - guard against registering the same named schedule twice,
    -- which would otherwise double the heater polling rate.
    local interval = tonumber(prefs.pollInterval) or 10
    if interval > 0 and not driver._heater_poll_scheduled then
      driver._heater_poll_scheduled = true
      driver:call_on_schedule(interval, function()
        local ok2, err2 = pcall(function() driver:poll_all_devices() end)
        if not ok2 then
          log.error(string.format("[Init] Heater polling tick failed (recovered): %s", tostring(err2)))
        end
      end, "HeaterStatusPolling")
    end
  end
end

local function device_info_changed(driver, device, event, args)
  log.info(string.format("[Init] Device info changed: %s", device.device_network_id))
  if device.device_network_id == "commax-bridge" then
    local prefs = device.preferences or {}
    local ip, port, verr = validate_ew11_prefs(prefs.ew11Ip, prefs.ew11Port)
    if verr then
      log.error(string.format("[Init] Invalid EW11 preferences after change (%s) - keeping previous connection", verr))
    elseif driver.ew11 then
      driver.ew11:update_config(ip, port)
    end

    local ok, err = pcall(function() driver:sync_child_devices(device) end)
    if not ok then
      log.error(string.format("[Init] sync_child_devices failed: %s", tostring(err)))
    end
  end
end

local function device_removed(driver, device)
  log.info(string.format("[Init] Device removed: %s", device.device_network_id))
  if device.device_network_id == "commax-bridge" and driver.ew11 then
    driver.ew11:stop()
    driver.ew11 = nil
  end
end

local function discovery_handler(driver, should_continue)
  log.info("[Discovery] Starting discovery for Commax Bridge...")
  if not driver:get_device_by_dni("commax-bridge") then
    local ok, err = pcall(function()
      driver:try_create_device({
        type = "LAN",
        device_network_id = "commax-bridge",
        label = "코맥스 월패드 브릿지",
        profile = "commax-bridge",
        manufacturer = "Commax",
        model = "EW11-RS485-Bridge"
      })
    end)
    if not ok then
      log.error(string.format("[Discovery] Failed to create bridge device: %s", tostring(err)))
    end
  end
end

-- =========================================================================
-- Instantiate Driver
-- =========================================================================

local driver = Driver("commax-ew11", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    infoChanged = device_info_changed,
    removed = device_removed
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handler.handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handler.handle_switch_off,
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = handler.handle_fan_speed,
    },
    [capabilities.thermostatMode.ID] = {
      [capabilities.thermostatMode.commands.setThermostatMode.NAME] = handler.handle_thermostat_mode,
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = handler.handle_heating_setpoint,
    },
    [capabilities.valve.ID] = {
      [capabilities.valve.commands.open.NAME] = handler.handle_valve_open,
      [capabilities.valve.commands.close.NAME] = handler.handle_valve_close,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handler.handle_refresh,
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = handler.handle_elevator_call_down,
    }
  }
})

driver:run()
