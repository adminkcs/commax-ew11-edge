local capabilities = require("st.capabilities")
local log = require("log")
local protocol = require("commax_protocol")

local handler = {}

--- Enqueue a packet on the bridge's EW11 connection, tolerating the bridge
--- not being ready yet (driver.ew11 nil - e.g. a child device's capability
--- command arrives before the bridge finishes init, or after the bridge was
--- removed but a stale child device tile is still commanded). Without this
--- guard, driver.ew11:send(...) would throw "attempt to index a nil value".
local function safe_send(driver, packet, ack_prefix)
  if not driver.ew11 then
    log.warn("[Handler] Command dropped: EW11 bridge is not connected/initialized yet")
    return
  end
  local ok, err = pcall(function() driver.ew11:send(packet, ack_prefix) end)
  if not ok then
    log.error(string.format("[Handler] Failed to enqueue command: %s", tostring(err)))
  end
end

--- Map parsed packet to SmartThings Child Device events
function handler.handle_parsed_packet(driver, parsed)
  if not parsed or not parsed.device_type then return end

  local target_dni = nil
  if parsed.device_type == "light" then
    target_dni = string.format("commax:light:%d", parsed.id)
  elseif parsed.device_type == "thermostat" then
    target_dni = string.format("commax:thermostat:%d", parsed.id)
  elseif parsed.device_type == "fan" then
    target_dni = string.format("commax:fan:%d", parsed.id)
  elseif parsed.device_type == "gas" then
    target_dni = "commax:gas:1"
  elseif parsed.device_type == "co2" or parsed.device_type == "pm25" or parsed.device_type == "pm10" then
    target_dni = "commax:airquality:1"
  elseif parsed.device_type == "outlet" then
    target_dni = string.format("commax:outlet:%d", parsed.id)
  elseif parsed.device_type == "elevator_status" then
    target_dni = "commax:elevator:1"
  end

  if not target_dni then return end

  local device = driver:get_device_by_dni(target_dni)
  if not device then
    -- Device tile might not be created or enabled
    return
  end

  -- 1. Light Event
  if parsed.device_type == "light" then
    if parsed.is_on then
      device:emit_event(capabilities.switch.switch.on())
    else
      device:emit_event(capabilities.switch.switch.off())
    end

  -- 2. Thermostat Event
  elseif parsed.device_type == "thermostat" then
    local has_supported = device.get_latest_state and device:get_latest_state("main", capabilities.thermostatMode.ID, capabilities.thermostatMode.supportedThermostatModes.NAME)
    if not has_supported then
      device:emit_event(capabilities.thermostatMode.supportedThermostatModes({ "off", "heat" }))
    end

    if parsed.mode == "heat" then
      device:emit_event(capabilities.thermostatMode.thermostatMode.heat())
    else
      device:emit_event(capabilities.thermostatMode.thermostatMode.off())
    end

    if parsed.state == "heating" then
      device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.heating())
    else
      device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.idle())
    end

    if parsed.current_temperature and parsed.current_temperature > 0 then
      device:emit_event(capabilities.temperatureMeasurement.temperature({ value = parsed.current_temperature, unit = "C" }))
    end

    if parsed.target_temperature and parsed.target_temperature > 0 then
      device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = parsed.target_temperature, unit = "C" }))
    end

  -- 3. Fan Event
  elseif parsed.device_type == "fan" then
    if parsed.is_on then
      device:emit_event(capabilities.switch.switch.on())
      device:emit_event(capabilities.fanSpeed.fanSpeed(parsed.speed or 1))
    else
      device:emit_event(capabilities.switch.switch.off())
      device:emit_event(capabilities.fanSpeed.fanSpeed(0))
    end

  -- 4. Gas Valve Event
  elseif parsed.device_type == "gas" then
    if parsed.is_open then
      device:emit_event(capabilities.valve.valve.open())
    else
      device:emit_event(capabilities.valve.valve.closed())
    end

  -- 5. Air Quality Events (CO2 / PM2.5 / PM10) - read-only sensor, no commands
  elseif parsed.device_type == "co2" then
    device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide({ value = parsed.ppm, unit = "ppm" }))
  elseif parsed.device_type == "pm10" then
    device:emit_event(capabilities.dustSensor.fineDustLevel({ value = parsed.ug_m3, unit = "ug/m3" }))
  elseif parsed.device_type == "pm25" then
    device:emit_event(capabilities.veryFineDustSensor.veryFineDustLevel({ value = parsed.ug_m3, unit = "ug/m3" }))

  -- 6. Outlet Event
  elseif parsed.device_type == "outlet" then
    if parsed.is_on then
      device:emit_event(capabilities.switch.switch.on())
    else
      device:emit_event(capabilities.switch.switch.off())
    end

  -- 7. Elevator Status Event
  elseif parsed.device_type == "elevator_status" then
    device:emit_event(capabilities.elevatorCall.callStatus.called())
    -- Reset to standby if no more status packets arrive in 4 seconds
    if handler._elevator_reset_timer and driver and driver.cancel_timer then
      driver:cancel_timer(handler._elevator_reset_timer)
    end
    if driver and driver.call_with_delay then
      handler._elevator_reset_timer = driver:call_with_delay(4, function()
        handler._elevator_reset_timer = nil
        local dev = driver:get_device_by_dni("commax:elevator:1")
        if dev then
          dev:emit_event(capabilities.elevatorCall.callStatus.standby())
        end
      end)
    end
  end
end

-- =========================================================================
-- SmartThings Capability Command Handlers
-- =========================================================================

local function get_effective_dni(device)
  return (device and (device.parent_assigned_child_key or device.device_network_id)) or ""
end

-- =========================================================================
-- SmartThings Capability Command Handlers
-- =========================================================================

function handler.handle_switch_on(driver, device, command)
  local dni = get_effective_dni(device)
  log.info(string.format("[Handler] Switch ON requested for %s (effective DNI: %s)", device.label or "unknown", dni))

  if dni:match("^commax:light:(%d+)$") then
    local light_id = tonumber(dni:match("^commax:light:(%d+)$"))
    local packet = protocol.build_light_command(light_id, true)
    device:emit_event(capabilities.switch.switch.on())
    safe_send(driver, packet, protocol.ack_light_command(light_id, true))
  elseif dni:match("^commax:fan:(%d+)$") then
    local fan_id = tonumber(dni:match("^commax:fan:(%d+)$"))
    local packet = protocol.build_fan_power(fan_id, true)
    device:emit_event(capabilities.switch.switch.on())
    device:emit_event(capabilities.fanSpeed.fanSpeed(1))
    safe_send(driver, packet, protocol.ack_fan_on())
  elseif dni:match("^commax:outlet:(%d+)$") then
    local outlet_id = tonumber(dni:match("^commax:outlet:(%d+)$"))
    local packet = protocol.build_outlet_command(outlet_id, true)
    device:emit_event(capabilities.switch.switch.on())
    safe_send(driver, packet, protocol.ack_outlet_command(outlet_id, true))
  else
    log.warn(string.format("[Handler] Switch ON received for unrecognized device: %s", dni))
  end
end

function handler.handle_switch_off(driver, device, command)
  local dni = get_effective_dni(device)
  log.info(string.format("[Handler] Switch OFF requested for %s (effective DNI: %s)", device.label or "unknown", dni))

  if dni:match("^commax:light:(%d+)$") then
    local light_id = tonumber(dni:match("^commax:light:(%d+)$"))
    local packet = protocol.build_light_command(light_id, false)
    device:emit_event(capabilities.switch.switch.off())
    safe_send(driver, packet, protocol.ack_light_command(light_id, false))
  elseif dni:match("^commax:fan:(%d+)$") then
    local fan_id = tonumber(dni:match("^commax:fan:(%d+)$"))
    local packet = protocol.build_fan_power(fan_id, false)
    device:emit_event(capabilities.switch.switch.off())
    device:emit_event(capabilities.fanSpeed.fanSpeed(0))
    safe_send(driver, packet, protocol.ack_fan_off())
  elseif dni:match("^commax:outlet:(%d+)$") then
    local outlet_id = tonumber(dni:match("^commax:outlet:(%d+)$"))
    local packet = protocol.build_outlet_command(outlet_id, false)
    device:emit_event(capabilities.switch.switch.off())
    safe_send(driver, packet, protocol.ack_outlet_command(outlet_id, false))
  else
    log.warn(string.format("[Handler] Switch OFF received for unrecognized device: %s", dni))
  end
end

function handler.handle_fan_speed(driver, device, command)
  local dni = get_effective_dni(device)
  local fan_id = tonumber(dni:match("^commax:fan:(%d+)$")) or 1
  local speed = command.args.speed

  -- command.args comes from the SmartThings capability layer, not from us -
  -- never assume it is a well-formed number.
  if type(speed) ~= "number" then
    log.warn(string.format("[Handler] Ignoring fan speed command with invalid args for %s", dni))
    return
  end
  log.info(string.format("[Handler] Fan speed %d requested for %s", speed, dni))

  if speed == 0 then
    device:emit_event(capabilities.switch.switch.off())
    device:emit_event(capabilities.fanSpeed.fanSpeed(0))
    safe_send(driver, protocol.build_fan_power(fan_id, false), protocol.ack_fan_off())
  else
    local clamped_speed = math.max(1, math.min(3, math.floor(speed)))
    device:emit_event(capabilities.switch.switch.on())
    device:emit_event(capabilities.fanSpeed.fanSpeed(clamped_speed))

    -- Commax wallpad ignores speed changes when fan power is OFF.
    -- If fan is not currently ON, send Power ON first so EW11 serial queue
    -- waits for Power ON ACK before transmitting the speed change packet.
    local current_switch = (device.get_latest_state and device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME))
    if current_switch ~= "on" then
      safe_send(driver, protocol.build_fan_power(fan_id, true), protocol.ack_fan_on())
    end
    safe_send(driver, protocol.build_fan_speed(fan_id, clamped_speed), protocol.ack_fan_speed())
  end
end

function handler.handle_thermostat_mode(driver, device, command)
  local dni = get_effective_dni(device)
  local thermo_id = tonumber(dni:match("^commax:thermostat:(%d+)$")) or 1
  local mode = command.args.mode
  log.info(string.format("[Handler] Thermostat mode '%s' requested for %s", tostring(mode), dni))

  if mode == "heat" then
    device:emit_event(capabilities.thermostatMode.thermostatMode.heat())
    safe_send(driver, protocol.build_thermostat_power(thermo_id, true), protocol.ack_thermostat_power(thermo_id, true))
  elseif mode == "off" then
    device:emit_event(capabilities.thermostatMode.thermostatMode.off())
    safe_send(driver, protocol.build_thermostat_power(thermo_id, false), protocol.ack_thermostat_power(thermo_id, false))
  else
    -- Only heat/off are confirmed by the reference protocol (heaters_new.yaml).
    log.warn(string.format("[Handler] Unsupported thermostat mode '%s' ignored for %s", tostring(mode), dni))
  end
end

function handler.handle_heating_setpoint(driver, device, command)
  local dni = get_effective_dni(device)
  local thermo_id = tonumber(dni:match("^commax:thermostat:(%d+)$")) or 1
  local temp = command.args.setpoint

  if type(temp) ~= "number" or temp < 5 or temp > 40 then
    log.warn(string.format("[Handler] Ignoring heating setpoint out of range/invalid for %s: %s", dni, tostring(temp)))
    return
  end
  log.info(string.format("[Handler] Heating setpoint %d requested for %s", temp, dni))

  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = temp, unit = "C" }))
  safe_send(driver, protocol.build_thermostat_temperature(thermo_id, temp), protocol.ack_thermostat_temperature(thermo_id))
end

function handler.handle_valve_close(driver, device, command)
  log.info("[Handler] Gas valve CLOSE requested")
  device:emit_event(capabilities.valve.valve.closed())
  safe_send(driver, protocol.build_gas_close(), protocol.ack_gas_close())
end

function handler.handle_valve_open(driver, device, command)
  log.warn("[Handler] Gas valve OPEN requested but blocked by protocol safety design.")
  device:emit_event(capabilities.valve.valve.closed())
end

--- Elevator call command (SmartThings elevatorCall capability)
function handler.handle_elevator_call(driver, device, command)
  log.info("[Handler] Elevator call requested")
  if device and device.emit_event then
    device:emit_event(capabilities.elevatorCall.callStatus.called())
  end

  local packet = protocol.build_elevator_call_down()

  local bridge = driver and driver.get_device_by_dni and driver:get_device_by_dni("commax-bridge")
  local prefs = (bridge and bridge.preferences) or {}
  local repeat_cnt = math.max(1, math.min(5, tonumber(prefs.elevatorCallCount) or 2))

  log.info(string.format("[Handler] Transmitting %d elevator down-call packet(s) burst (no ACK blocking)", repeat_cnt))
  for _ = 1, repeat_cnt do
    safe_send(driver, packet, nil)
  end

  -- Fallback auto-reset to standby after 10s if wallpad 0x23 packets don't take over
  if handler._elevator_reset_timer and driver and driver.cancel_timer then
    driver:cancel_timer(handler._elevator_reset_timer)
  end
  if driver and driver.call_with_delay then
    handler._elevator_reset_timer = driver:call_with_delay(10, function()
      handler._elevator_reset_timer = nil
      if device and device.emit_event then
        device:emit_event(capabilities.elevatorCall.callStatus.standby())
      end
    end)
  end
end

-- Backward compatibility alias
handler.handle_elevator_call_down = handler.handle_elevator_call

function handler.handle_refresh(driver, device, command)
  local dni = get_effective_dni(device)
  log.info(string.format("[Handler] Refresh requested for %s", dni))
  
  if dni:match("^commax:light:(%d+)$") then
    local light_id = tonumber(dni:match("^commax:light:(%d+)$"))
    safe_send(driver, protocol.build_light_query(light_id))
  elseif dni:match("^commax:thermostat:(%d+)$") then
    local thermo_id = tonumber(dni:match("^commax:thermostat:(%d+)$"))
    safe_send(driver, protocol.build_thermostat_query(thermo_id))
  elseif dni:match("^commax:outlet:(%d+)$") then
    local outlet_id = tonumber(dni:match("^commax:outlet:(%d+)$"))
    safe_send(driver, protocol.build_outlet_query(outlet_id))
  elseif dni == "commax:elevator:1" then
    device:emit_event(capabilities.elevatorCall.callStatus.standby())
  elseif dni == "commax-bridge" then
    local ok, err = pcall(function() driver:sync_child_devices(device) end)
    if not ok then
      log.error(string.format("[Handler] sync_child_devices on refresh failed: %s", tostring(err)))
    end
    driver:poll_all_devices()
  end
end

--- Called by EW11 when a command fails after all ACK retries are exhausted.
--- Instead of guessing the device state, query hardware for the real state
--- so SmartThings UI reconciles with reality (the command might have partially
--- succeeded - the ACK could have been lost while the relay actually toggled).
function handler.handle_command_failed(driver, raw_packet, ack_prefix)
  if type(raw_packet) ~= "string" or #raw_packet < 2 then return end
  local header = string.byte(raw_packet, 1)
  local id = string.byte(raw_packet, 2)

  if header == protocol.CMD_LIGHT then
    log.warn(string.format("[Handler] Light %d command failed, querying real state", id))
    safe_send(driver, protocol.build_light_query(id))
  elseif header == protocol.CMD_OUTLET then
    log.warn(string.format("[Handler] Outlet %d command failed, querying real state", id))
    safe_send(driver, protocol.build_outlet_query(id))
  elseif header == protocol.CMD_THERMO then
    log.warn(string.format("[Handler] Thermostat %d command failed, querying real state", id))
    safe_send(driver, protocol.build_thermostat_query(id))
  else
    log.warn(string.format("[Handler] Command 0x%02X failed, no auto-recovery query available", header))
  end
end

return handler
