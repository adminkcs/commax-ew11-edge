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
  end
end

-- =========================================================================
-- SmartThings Capability Command Handlers
-- =========================================================================

function handler.handle_switch_on(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("[Handler] Switch ON requested for %s", dni))

  if dni:match("^commax:light:(%d+)$") then
    local light_id = tonumber(dni:match("^commax:light:(%d+)$"))
    local packet = protocol.build_light_command(light_id, true)
    safe_send(driver, packet, protocol.ack_light_command(light_id, true))
  elseif dni:match("^commax:fan:(%d+)$") then
    local fan_id = tonumber(dni:match("^commax:fan:(%d+)$"))
    local packet = protocol.build_fan_power(fan_id, true)
    safe_send(driver, packet, protocol.ack_fan_on())
  elseif dni:match("^commax:outlet:(%d+)$") then
    local outlet_id = tonumber(dni:match("^commax:outlet:(%d+)$"))
    local packet = protocol.build_outlet_command(outlet_id, true)
    safe_send(driver, packet, protocol.ack_outlet_command(outlet_id, true))
  end
end

function handler.handle_switch_off(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("[Handler] Switch OFF requested for %s", dni))

  if dni:match("^commax:light:(%d+)$") then
    local light_id = tonumber(dni:match("^commax:light:(%d+)$"))
    local packet = protocol.build_light_command(light_id, false)
    safe_send(driver, packet, protocol.ack_light_command(light_id, false))
  elseif dni:match("^commax:fan:(%d+)$") then
    local fan_id = tonumber(dni:match("^commax:fan:(%d+)$"))
    local packet = protocol.build_fan_power(fan_id, false)
    safe_send(driver, packet, protocol.ack_fan_off())
  elseif dni:match("^commax:outlet:(%d+)$") then
    local outlet_id = tonumber(dni:match("^commax:outlet:(%d+)$"))
    local packet = protocol.build_outlet_command(outlet_id, false)
    safe_send(driver, packet, protocol.ack_outlet_command(outlet_id, false))
  end
end

function handler.handle_fan_speed(driver, device, command)
  local dni = device.device_network_id
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
    safe_send(driver, protocol.build_fan_power(fan_id, false), protocol.ack_fan_off())
  else
    safe_send(driver, protocol.build_fan_speed(fan_id, speed), protocol.ack_fan_speed())
  end
end

function handler.handle_thermostat_mode(driver, device, command)
  local dni = device.device_network_id
  local thermo_id = tonumber(dni:match("^commax:thermostat:(%d+)$")) or 1
  local mode = command.args.mode
  log.info(string.format("[Handler] Thermostat mode '%s' requested for %s", tostring(mode), dni))

  if mode == "heat" then
    safe_send(driver, protocol.build_thermostat_power(thermo_id, true), protocol.ack_thermostat_power(thermo_id, true))
  elseif mode == "off" then
    safe_send(driver, protocol.build_thermostat_power(thermo_id, false), protocol.ack_thermostat_power(thermo_id, false))
  else
    -- Only heat/off are confirmed by the reference protocol (heaters_new.yaml).
    -- Any other mode (e.g. "auto"/"cool") is not supported - ignore rather
    -- than send an unconfirmed/guessed packet.
    log.warn(string.format("[Handler] Unsupported thermostat mode '%s' ignored for %s", tostring(mode), dni))
  end
end

function handler.handle_heating_setpoint(driver, device, command)
  local dni = device.device_network_id
  local thermo_id = tonumber(dni:match("^commax:thermostat:(%d+)$")) or 1
  local temp = command.args.setpoint

  if type(temp) ~= "number" or temp < 5 or temp > 40 then
    log.warn(string.format("[Handler] Ignoring heating setpoint out of range/invalid for %s: %s", dni, tostring(temp)))
    return
  end
  log.info(string.format("[Handler] Heating setpoint %d requested for %s", temp, dni))

  safe_send(driver, protocol.build_thermostat_temperature(thermo_id, temp), protocol.ack_thermostat_temperature(thermo_id))
end

function handler.handle_valve_close(driver, device, command)
  log.info("[Handler] Gas valve CLOSE requested")
  safe_send(driver, protocol.build_gas_close(), protocol.ack_gas_close())
end

function handler.handle_valve_open(driver, device, command)
  log.warn("[Handler] Gas valve OPEN requested but blocked by protocol safety design.")
  device:emit_event(capabilities.valve.valve.closed())
end

--- Elevator down-call is a momentary button. CONFIRMED 2026-09-17 by real
--- capture: the physical trigger (a separate RS485-to-Matter bridge on the
--- same bus) sends the exact same command packet TWICE, ~12ms apart, each
--- separately ACKed, for a single logical call - not once. Enqueue it
--- repeat_cnt times (default 2, configurable via elevatorCallCount preference)
--- without confusing this with ordinary command ACK retry counts.
function handler.handle_elevator_call_down(driver, device, command)
  log.info("[Handler] Elevator down-call requested")
  local packet = protocol.build_elevator_call_down()
  local ack = protocol.ack_elevator_call_down()

  local bridge = driver and driver.get_device_by_dni and driver:get_device_by_dni("commax-bridge")
  local prefs = (bridge and bridge.preferences) or {}
  local repeat_cnt = math.max(1, math.min(5, tonumber(prefs.elevatorCallCount) or 2))

  log.info(string.format("[Handler] Enqueuing %d elevator down-call packet(s)", repeat_cnt))
  for _ = 1, repeat_cnt do
    safe_send(driver, packet, ack)
  end
end

function handler.handle_refresh(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("[Handler] Refresh requested for %s", dni))
  
  if dni:match("^commax:light:(%d+)$") then
    -- Confirmed by real EW11 capture 2026-09-16 (see commax_protocol.lua).
    local light_id = tonumber(dni:match("^commax:light:(%d+)$"))
    safe_send(driver, protocol.build_light_query(light_id))
  elseif dni:match("^commax:thermostat:(%d+)$") then
    local thermo_id = tonumber(dni:match("^commax:thermostat:(%d+)$"))
    safe_send(driver, protocol.build_thermostat_query(thermo_id))
  elseif dni:match("^commax:outlet:(%d+)$") then
    -- Confirmed by real EW11 capture 2026-09-17 (see commax_protocol.lua).
    local outlet_id = tonumber(dni:match("^commax:outlet:(%d+)$"))
    safe_send(driver, protocol.build_outlet_query(outlet_id))
  elseif dni == "commax-bridge" then
    driver:poll_all_devices()
  end
end

return handler
