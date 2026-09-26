local capabilities = require("st.capabilities")
local log = require("log")
local protocol = require("commax_protocol")

local handler = {}

--- Enqueue a packet on the bridge's EW11 connection, tolerating the bridge
--- not being ready yet (driver.ew11 nil - e.g. a child device's capability
--- command arrives before the bridge finishes init, or after the bridge was
--- removed but a stale child device tile is still commanded). Without this
--- guard, driver.ew11:send(...) would throw "attempt to index a nil value".
local function safe_send(driver, packet, ack_prefix, opts)
  if not driver.ew11 then
    log.warn("[Handler] Command dropped: EW11 bridge is not connected/initialized yet")
    return
  end
  local ok, err = pcall(function() driver.ew11:send(packet, ack_prefix, opts) end)
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

  -- Scoped diagnostic logging for air quality only (CO2/PM2.5/PM10 have no
  -- ACK/poll path to confirm success, so this is the only way to tell
  -- "device not found" apart from "found but emit had no visible effect" -
  -- added 2026-09-26 while chasing reports of CO2/PM staying blank/NaN.
  -- Deliberately gated on device_type so no other device's logging changes.
  local is_air_quality = (parsed.device_type == "co2" or parsed.device_type == "pm25" or parsed.device_type == "pm10")
  if is_air_quality then
    log.info(string.format("[AirQuality] Parsed packet: type=%s dni=%s ppm=%s ug_m3=%s",
      tostring(parsed.device_type), tostring(target_dni), tostring(parsed.ppm), tostring(parsed.ug_m3)))
  end

  local device = driver:get_device_by_dni(target_dni)
  if not device then
    if is_air_quality then
      log.warn(string.format("[AirQuality] Child device NOT FOUND for dni=%s (type=%s) - device tile may not be created/enabled", tostring(target_dni), tostring(parsed.device_type)))
    end
    -- Device tile might not be created or enabled
    return
  end

  if is_air_quality then
    log.info(string.format("[AirQuality] Child device found: %s (label=%s)", tostring(target_dni), tostring(device.label)))
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
  -- Capability mapping CONFIRMED 2026-09-26 via `smartthings capabilities`
  -- against the real platform: dustSensor="Dust Sensor" (PM10),
  -- fineDustSensor="Fine Dust Sensor" (PM2.5), veryFineDustSensor="Very
  -- Fine Dust Sensor" (PM1.0, not tracked here - no PM1.0 data on this
  -- bus). PM2.5 was previously wired to veryFineDustSensor (the PM1.0
  -- capability) by mistake - fixed here to fineDustSensor.
  --
  -- Attribute VALUE SHAPE also CONFIRMED 2026-09-26 via `smartthings
  -- capabilities`: carbonDioxide is type "number" and dustSensor/
  -- fineDustSensor's *DustLevel are type "integer" - plain scalars, not
  -- objects. Previously passed as {value=..., unit=...} tables, which
  -- don't match a plain number/integer attribute - very likely why these
  -- events never rendered in the app even though emit_event was reached.
  -- Now passing the bare numeric value.
  elseif parsed.device_type == "co2" then
    log.info(string.format("[AirQuality] Emitting CO2: %s ppm", tostring(parsed.ppm)))
    device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide(parsed.ppm))
  elseif parsed.device_type == "pm10" then
    log.info(string.format("[AirQuality] Emitting PM10: %s ug/m3", tostring(parsed.ug_m3)))
    device:emit_event(capabilities.dustSensor.fineDustLevel(parsed.ug_m3))
  elseif parsed.device_type == "pm25" then
    log.info(string.format("[AirQuality] Emitting PM2.5: %s ug/m3", tostring(parsed.ug_m3)))
    device:emit_event(capabilities.fineDustSensor.fineDustLevel(parsed.ug_m3))

  -- 6. Outlet Event
  elseif parsed.device_type == "outlet" then
    if parsed.is_on then
      device:emit_event(capabilities.switch.switch.on())
    else
      device:emit_event(capabilities.switch.switch.off())
    end

  -- 7. Elevator Status Event
  elseif parsed.device_type == "elevator_status" then
    log.info("[ELEVATOR] Wallpad broadcasted elevator status (0x23) -> keeping called state")
    device:emit_event(capabilities.elevatorCall.callStatus.called())
    -- Reset to standby if no more status packets arrive in 4 seconds
    if handler._elevator_reset_timer and driver and driver.cancel_timer then
      driver:cancel_timer(handler._elevator_reset_timer)
    end
    if driver and driver.call_with_delay then
      handler._elevator_reset_timer = driver:call_with_delay(4, function()
        handler._elevator_reset_timer = nil
        log.info("[ELEVATOR] Status packets stopped -> resetting to standby")
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

--- Send the actual ACK-gated down-call burst (packet content confirmed
--- correct, but only effective when preceded by send_elevator_preamble
--- below - see ELEVATOR_CALL_PREAMBLE comment in commax_protocol.lua).
local function send_elevator_call_burst(driver, device, call_cnt)
  local packet = protocol.build_elevator_call_down()
  local ack = protocol.ack_elevator_call_down()

  local opts = {
    tag = "elevator",
    burst_count = call_cnt,     -- 반복 전송 횟수: 엘리베이터 호출 반복 전송 설정(elevatorCallCount) 준수 (기본 2회)
    burst_delay = 0.015,        -- 재전송 지연시간: 모니터링 실측 결과 기반 15ms
    retry_count = call_cnt,     -- ACK 유실 시 재시도 횟수도 동일한 설정(elevatorCallCount)을 따름 -
                                -- 바쁜 RS485 버스에서 단일 스텝의 ACK가 폴링 트래픽과 충돌해
                                -- 유실되는 경우가 실측으로 확인됐고, retry_count=0이면 그 즉시
                                -- 호출 전체가 실패했다 (2026-09-20 실캡처로 확인)
    ack_timeout = 1.0,          -- 응답 대기 시간: 모니터링 실측 결과 기반 1000ms (월패드 처리 지연 대응)
    rx_timeout = 0.05,          -- 수신 버퍼 정리시간: 모니터링 실측 결과 기반 50ms
    on_ack = function()
      log.info("[ELEVATOR] Wallpad ACK received, call confirmed")
    end,
    on_fail = function()
      log.warn("[ELEVATOR] Transmission completed without ACK confirmation, reverting to standby")
      if handler._elevator_reset_timer and driver and driver.cancel_timer then
        driver:cancel_timer(handler._elevator_reset_timer)
        handler._elevator_reset_timer = nil
      end
      local dev = driver:get_device_by_dni("commax:elevator:1") or device
      if dev and dev.emit_event then
        dev:emit_event(capabilities.elevatorCall.callStatus.standby())
      end
    end,
  }

  log.info(string.format(
    "[ELEVATOR] Enqueueing %d-packet call (delay=15ms, ack_wait=1000ms, rx_buf=50ms, retry=%d) per elevatorCallCount preference",
    call_cnt, call_cnt))
  safe_send(driver, packet, ack, opts)
end

-- Preamble gaps CONFIRMED 2026-09-21 by real-hardware capture of a working
-- call from the other vendor's bridge (down to the millisecond) - see
-- ELEVATOR_CALL_PREAMBLE comment in commax_protocol.lua. Do not change
-- without a fresh real capture to compare against.
local ELEVATOR_PREAMBLE_GAPS = { 0.007, 0.301, 0.309 }

--- Send the elevator call preamble broadcast 4x with the exact captured
--- gaps, fire-and-forget (no ack expected - see protocol comment), then
--- invoke on_done (which sends the actual down-call burst). Chained via
--- call_with_delay rather than a blocking sleep, since this runs in the
--- capability-command handler, not a cosock coroutine.
local function send_elevator_preamble(driver, on_done)
  local preamble = protocol.build_elevator_call_preamble()
  safe_send(driver, preamble, nil, { tag = "elevator_preamble" })

  local function schedule_next(i)
    if i > #ELEVATOR_PREAMBLE_GAPS then
      on_done()
      return
    end
    if driver and driver.call_with_delay then
      driver:call_with_delay(ELEVATOR_PREAMBLE_GAPS[i], function()
        safe_send(driver, preamble, nil, { tag = "elevator_preamble" })
        schedule_next(i + 1)
      end)
    else
      -- No timer support (e.g. a bare test double) - fall back to sending
      -- the remaining preamble copies immediately rather than dropping them.
      safe_send(driver, preamble, nil, { tag = "elevator_preamble" })
      schedule_next(i + 1)
    end
  end
  schedule_next(1)
end

--- Elevator call command (SmartThings elevatorCall capability)
function handler.handle_elevator_call(driver, device, command)
  log.info("[ELEVATOR] Down-call requested via SmartThings")
  if device and device.emit_event then
    device:emit_event(capabilities.elevatorCall.callStatus.called())
  end

  local bridge = driver and driver.get_device_by_dni and driver:get_device_by_dni("commax-bridge")
  local prefs = (bridge and bridge.preferences) or {}
  local call_cnt = tonumber(prefs.elevatorCallCount) or 2
  if call_cnt < 1 then call_cnt = 1 end
  if call_cnt > 5 then call_cnt = 5 end

  -- Fallback auto-reset to standby after 15s if wallpad 0x23 packets don't take over
  if handler._elevator_reset_timer and driver and driver.cancel_timer then
    driver:cancel_timer(handler._elevator_reset_timer)
  end
  if driver and driver.call_with_delay then
    handler._elevator_reset_timer = driver:call_with_delay(15, function()
      handler._elevator_reset_timer = nil
      local dev = driver:get_device_by_dni("commax:elevator:1") or device
      if dev and dev.emit_event then
        log.info("[ELEVATOR] Timeout fallback: resetting to standby")
        dev:emit_event(capabilities.elevatorCall.callStatus.standby())
      end
    end)
  end

  log.info("[ELEVATOR] Sending call preamble broadcast (4x, 7/301/309ms gaps) before down-call burst")
  send_elevator_preamble(driver, function()
    send_elevator_call_burst(driver, device, call_cnt)
  end)
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
