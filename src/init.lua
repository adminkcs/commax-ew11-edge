local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local socket = require("cosock.socket")
local log = require("log")
local EW11 = require("ew11")
local protocol = require("commax_protocol")
local handler = require("device_handler")

local commax_driver = {}

function commax_driver:get_device_by_dni(dni)
  if not self or not self.get_devices then return nil end
  for _, device in ipairs(self:get_devices()) do
    if device.device_network_id == dni or device.parent_assigned_child_key == dni then
      return device
    end
  end
  return nil
end

--- Create a single child device with rate limiting to prevent SmartThings cloud API drops
local function safe_create_device(self, spec)
  if spec.type == "EDGE_CHILD" and not spec.parent_assigned_child_key then
    spec.parent_assigned_child_key = spec.device_network_id
  end
  local ok, err = pcall(function() return self:try_create_device(spec) end)
  if not ok then
    log.error(string.format("[Init] Failed to create device %s: %s", spec.device_network_id or spec.parent_assigned_child_key, tostring(err)))
  end
  -- Brief yield to prevent SmartThings cloud RPC flooding when creating multiple child devices
  pcall(function() socket.sleep(0.05) end)
end

--- Create Child Devices according to Bridge Preferences
function commax_driver:sync_child_devices(bridge_device)
  local prefs = bridge_device.preferences or {}

  -- Preferences come from user input in the SmartThings app - clamp to the
  -- profile's declared range rather than trusting them blindly.
  local enable_light = (prefs.enableLight ~= false)
  local light_count = enable_light and math.max(0, math.min(9, tonumber(prefs.lightCount) or 4)) or 0

  local enable_heating = (prefs.enableHeating ~= false)
  local heater_count = enable_heating and math.max(0, math.min(9, tonumber(prefs.heaterCount) or 4)) or 0

  local enable_outlet = (prefs.enableOutlet ~= false)
  local outlet_count = enable_outlet and math.max(0, math.min(12, tonumber(prefs.outletCount) or 10)) or 0

  local enable_fan = (prefs.enableFan ~= false)
  local enable_gas = (prefs.enableGas ~= false)
  local enable_air_quality = (prefs.enableAirQuality ~= false)
  local enable_elevator = (prefs.enableElevator ~= false)

  -- 1. Create Lights
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

  -- 8. Check for devices that have been disabled in Preferences
  -- [SmartThings 제한]: SmartThings Edge SDK does not provide a driver API
  -- (e.g. driver:try_delete_device) to delete child devices programmatically.
  -- Log explicit warnings so users know they must delete them from the ST app.
  if self.get_devices then
    for _, dev in ipairs(self:get_devices()) do
      if dev.device_network_id ~= "commax-bridge" and dev.parent_device_id == bridge_device.id then
        local dni = dev.device_network_id
        local is_stale = false
        local l_id = dni:match("^commax:light:(%d+)$")
        local t_id = dni:match("^commax:thermostat:(%d+)$")
        local o_id = dni:match("^commax:outlet:(%d+)$")
        if l_id and (not enable_light or tonumber(l_id) > light_count) then
          is_stale = true
        elseif t_id and (not enable_heating or tonumber(t_id) > heater_count) then
          is_stale = true
        elseif o_id and (not enable_outlet or tonumber(o_id) > outlet_count) then
          is_stale = true
        elseif dni == "commax:fan:1" and not enable_fan then
          is_stale = true
        elseif dni == "commax:gas:1" and not enable_gas then
          is_stale = true
        elseif dni == "commax:airquality:1" and not enable_air_quality then
          is_stale = true
        elseif dni == "commax:elevator:1" and not enable_elevator then
          is_stale = true
        end

        if is_stale then
          log.warn(string.format("[Init] [SmartThings 제한] Device %s (%s) is disabled by Settings, but Edge SDK has no programmatic device deletion API. Please remove it manually in the SmartThings app.", dev.label, dni))
        end
      end
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

--- Validate EW11 connection preferences before acting on them.
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

local function build_ew11_config(prefs)
  prefs = prefs or {}
  return {
    tx_retry_cnt = prefs.txRetryCount,
    tx_delay_ms = prefs.txDelay,
    rx_timeout_ms = prefs.rxTimeout,
    ack_timeout_ms = prefs.ackTimeout,
  }
end

-- =========================================================================
-- Driver Lifecycle Handlers
-- =========================================================================

local function device_init(driver, device)
  log.info(string.format("[Init] Device initialized: %s (DNI: %s)", device.label, device.device_network_id))

  if device.device_network_id == "commax-bridge" then
    local prefs = device.preferences or {}
    local ip, port, verr = validate_ew11_prefs(prefs.ew11Ip or "192.168.50.243", prefs.ew11Port or 8899)
    local config = build_ew11_config(prefs)

    if verr then
      log.error(string.format("[Init] Invalid EW11 preferences (%s) - not (re)connecting until fixed in Settings", verr))
    else
      if not driver.ew11 then
        driver.ew11 = EW11.new(driver, ip, port, function(parsed)
          handler.handle_parsed_packet(driver, parsed)
        end, config)
        driver.ew11:start()
      else
        driver.ew11:update_config(ip, port, config)
      end
    end

    local ok, err = pcall(function() driver:sync_child_devices(device) end)
    if not ok then
      log.error(string.format("[Init] sync_child_devices failed: %s", tostring(err)))
    end

    -- Start periodic query schedule if enabled.
    local interval = tonumber(prefs.refreshTime) or tonumber(prefs.pollInterval) or 10
    if interval > 0 and not driver._heater_poll_scheduled then
      driver._heater_poll_scheduled = true
      driver:call_on_schedule(interval, function()
        local ok2, err2 = pcall(function() driver:poll_all_devices() end)
        if not ok2 then
          log.error(string.format("[Init] Heater polling tick failed (recovered): %s", tostring(err2)))
        end
      end, "HeaterStatusPolling")
    end
  else
    -- Initialize Child Device baseline capability events so SmartThings UI does not show "all ON" or "unknown"
    local dni = device.parent_assigned_child_key or device.device_network_id or ""
    if dni:match("^commax:light:") then
      pcall(function() device:emit_event(capabilities.switch.switch.off()) end)
    elseif dni:match("^commax:outlet:") then
      pcall(function() device:emit_event(capabilities.switch.switch.off()) end)
    elseif dni:match("^commax:fan:") then
      pcall(function()
        device:emit_event(capabilities.switch.switch.off())
        device:emit_event(capabilities.fanSpeed.fanSpeed(0))
      end)
    elseif dni:match("^commax:thermostat:") then
      pcall(function()
        device:emit_event(capabilities.thermostatMode.thermostatMode.off())
        device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.idle())
      end)
    elseif dni == "commax:gas:1" then
      pcall(function() device:emit_event(capabilities.valve.valve.closed()) end)
    end
  end
end

local function device_info_changed(driver, device, event, args)
  log.info(string.format("[Init] Device info changed: %s", device.device_network_id))
  if device.device_network_id == "commax-bridge" then
    local old_prefs = (args and args.old_st_store and args.old_st_store.preferences) or {}
    local prefs = device.preferences or {}

    log.info(string.format("[Init] Preferences diff: IP %s -> %s, Port %s -> %s, Retry %s -> %s, Delay %s -> %s, ACK_TO %s -> %s, Refresh %s -> %s",
      tostring(old_prefs.ew11Ip), tostring(prefs.ew11Ip),
      tostring(old_prefs.ew11Port), tostring(prefs.ew11Port),
      tostring(old_prefs.txRetryCount), tostring(prefs.txRetryCount),
      tostring(old_prefs.txDelay), tostring(prefs.txDelay),
      tostring(old_prefs.ackTimeout), tostring(prefs.ackTimeout),
      tostring(prefs.refreshTime or prefs.pollInterval)))

    local ip, port, verr = validate_ew11_prefs(prefs.ew11Ip, prefs.ew11Port)
    local config = build_ew11_config(prefs)
    if verr then
      log.error(string.format("[Init] Invalid EW11 preferences after change (%s) - keeping previous connection", verr))
    elseif driver.ew11 then
      driver.ew11:update_config(ip, port, config)
    end

    local ok, err = pcall(function() driver:sync_child_devices(device) end)
    if not ok then
      log.error(string.format("[Init] sync_child_devices failed: %s", tostring(err)))
    end
  end
end

local function device_removed(driver, device)
  log.info(string.format("[Init] Device removed: %s", device.device_network_id))
  if device.device_network_id == "commax-bridge" then
    if driver.ew11 then
      driver.ew11:stop()
      driver.ew11 = nil
    end
    -- Reset so a later re-add of the bridge (discovery after removal, still
    -- within the same driver process) can register the heater polling
    -- schedule again - device_init only schedules it once per process via
    -- this same flag, and without resetting it here a bridge remove+recreate
    -- cycle would silently lose heater polling until the whole driver
    -- process restarts.
    driver._heater_poll_scheduled = false
  end
end

local function discovery_handler(driver, opts, should_continue)
  log.info("[Discovery] START")
  local existing = driver:get_device_by_dni("commax-bridge")
  log.info(string.format("[Discovery] Existing device: %s", tostring(existing ~= nil)))
  if not existing then
    log.info("[Discovery] Creating device: commax-bridge")
    local ok, err = pcall(function()
      return driver:try_create_device({
        type = "LAN",
        device_network_id = "commax-bridge",
        label = "코맥스 월패드 브릿지",
        profile = "commax-bridge",
        manufacturer = "Commax",
        model = "EW11-RS485-Bridge"
      })
    end)
    if not ok then
      log.error(string.format("[Discovery] ERROR: %s", tostring(err)))
    else
      log.info(string.format("[Discovery] try_create_device result: %s", tostring(ok)))
    end
  else
    log.info("[Discovery] Existing device found, skipping creation")
  end
  log.info("[Discovery] END")
end

-- =========================================================================
-- Instantiate Driver
-- =========================================================================

commax_driver.discovery = discovery_handler
commax_driver.lifecycle_handlers = {
  init = device_init,
  infoChanged = device_info_changed,
  removed = device_removed
}
commax_driver.capability_handlers = {
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

local driver = Driver("commax-ew11", commax_driver)
driver.get_device_by_dni = commax_driver.get_device_by_dni
driver.sync_child_devices = commax_driver.sync_child_devices
driver.poll_all_devices = commax_driver.poll_all_devices

driver:run()
