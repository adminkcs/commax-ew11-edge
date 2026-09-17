local bcd = require("bcd")

local protocol = {
  PACKET_LEN = 8,
  
  -- Header Definitions
  -- REQ_LIGHT: confirmed 2026-09-16 by a real capture from our own EW11
  -- (tools/capture_ew11.ps1) - passively observed on the bus as
  -- "30 01 00 00 00 00 00 31", "30 02 ...", incrementing ID with an
  -- all-zero payload, immediately followed by the matching B0 state reply.
  -- Previously removed for lack of source evidence; real hardware confirms
  -- the original guess was in fact correct.
  CMD_LIGHT        = 0x31,
  REQ_LIGHT        = 0x30,
  STATE_LIGHT      = 0xB0,
  ACK_LIGHT        = 0xB1,

  -- Thermostat: header is 0x82 (state) / 0x84 (ack) ONLY.
  -- 0x80 / 0x81 / 0x83 are NOT headers - they are the power/mode byte at
  -- index 2 of the payload (off / heat-idle / heat-active respectively).
  -- Source: gallery/commax/heaters_new.yaml description table.
  -- CONFIRMED 2026-09-16 by real EW11 capture: header 0x82 with byte1=0x80
  -- ("82 80 02 27 05 00 00 30") and byte1=0x81 ("82 81 01 28 12 00 00 3E")
  -- both observed exactly as coded here, alongside the matching 0x02 query
  -- packet ("02 01/02/03 ..."). THERMO_HEATING (0x83, actively firing) was
  -- not observed in this capture (heater was idle) - still unconfirmed.
  CMD_THERMO       = 0x04,
  REQ_THERMO       = 0x02,
  STATE_THERMO     = 0x82,
  ACK_THERMO       = 0x84,
  THERMO_OFF       = 0x80,
  THERMO_HEAT_IDLE = 0x81,
  THERMO_HEATING   = 0x83,

  -- Fan: confirmed from actual homenet2mqtt entities code (fan_new.yaml),
  -- not from the (inconsistent) description-table comment in that same file.
  -- State broadcasts match the bit pattern (byte & 0xF1) == 0xF0, i.e. the
  -- header's high nibble is 0xF and bit0 is clear (covers 0xF0, 0xF6, ...).
  -- Command header is 0x78, ack header is 0xF8.
  -- CONFIRMED 2026-09-16 by real EW11 capture: "F6 00 01 00 00 00 00 F7"
  -- observed (header 0xF6 matches the mask, byte1=0x00 -> OFF, byte2=ID 1) -
  -- matches this parsing exactly. Only the OFF state was observed; ON/speed
  -- values were not captured (fan was idle).
  CMD_FAN          = 0x78,
  ACK_FAN          = 0xF8,
  STATE_FAN_MASK   = 0xF1,
  STATE_FAN_VALUE  = 0xF0,

  -- Gas valve state bytes CORRECTED 2026-09-16 from a real EW11 capture:
  -- our home's wallpad broadcasts "90 50 50 00 00 00 00 30" while closed -
  -- i.e. status byte 0x50, NOT 0x40 as the homenet2mqtt source described.
  -- This directly contradicts the reference repo for OUR unit; real
  -- hardware evidence overrides it per the "don't guess" policy (real
  -- capture beats every secondary source). The OPEN byte (0xA0) has not
  -- been directly observed (valve was never opened during capture) - it is
  -- taken from kimtc99/HAaddons, which is the same source that correctly
  -- predicted our real CLOSED byte (0x50), raising confidence in its
  -- paired OPEN value. Still flagged in README as not directly confirmed.
  CMD_GAS          = 0x11,
  STATE_GAS        = 0x90,
  ACK_GAS          = 0x91,
  GAS_OPEN         = 0xA0,
  GAS_CLOSED       = 0x50,

  -- Air quality sensors (read-only, passively broadcast - no commands).
  -- CONFIRMED 2026-09-17 by real EW11 capture, matched live against the
  -- wallpad's own display: "C8 31 01 13 13 00 01 21" arrived while the
  -- wallpad showed PM2.5=1 and "C8 3F 01 13 13 00 01 2F" while it showed
  -- PM10=1, and "F7 82 01 00 1A 13 13 BA" arrived while it showed CO2=1313
  -- - then tracked live as CO2 fell (1313 -> 1235 -> 1223 -> 1221) exactly
  -- matching the same two trailing bytes each time. In all three, the
  -- value is bytes 6-7 (1-based, i.e. the last 2 bytes before checksum)
  -- decoded as one 2-byte BCD number (bcd.decode_word). This matches the
  -- "index 5 length 2 decode bcd" field described in homenet2mqtt's
  -- haatz_air_quality_sensors.yaml, except our unit's PM10 second-byte
  -- (0x3F) differs from that doc's 0x39 - our real value is used here.
  HEAD_CO2         = 0xF7,
  CO2_SUB1         = 0x82,
  CO2_SUB2         = 0x01,
  HEAD_DUST        = 0xC8,
  DUST_PM25        = 0x31,
  DUST_PM10        = 0x3F,
  DUST_SUB2        = 0x01,

  -- Outlet (콘센트): CONFIRMED 2026-09-17 by real command/ack/state
  -- correlation on our own bus. Toggling outlet 1 produced, in order:
  --   command OFF: "7A 01 01 00 00 00 00 7C"
  --   ack     OFF: "FA 10 01 10 00 00 00 1B"
  --   command ON:  "7A 01 01 01 00 00 00 7D"
  --   ack     ON:  "FA 11 01 10 00 00 00 1C"
  -- and the passive state polling (query header 0x79, ID, attr 0x01/0x02)
  -- immediately reflected the same change: "F9 10 01 10..." (off) /
  -- "F9 11 01 10..." (on) - i.e. STATE/ACK byte1 0x10=OFF, 0x11=ON, byte2=ID.
  -- The 4th payload byte in the query/state pair (0x01/0x02 in the query,
  -- 0x10/0x20 in the reply) selects which attribute is being read; only
  -- attr 0x01/0x10 (power state) is used here - the meaning of attr
  -- 0x02/0x20 (possibly power consumption) is not confirmed and unused.
  CMD_OUTLET       = 0x7A,
  ACK_OUTLET       = 0xFA,
  REQ_OUTLET       = 0x79,
  STATE_OUTLET     = 0xF9,
  OUTLET_ON        = 0x11,
  OUTLET_OFF       = 0x10,

  -- Elevator call (하강 호출만 확인): CONFIRMED 2026-09-17 by real capture
  -- while calling the elevator down via a separate RS485-to-Matter bridge
  -- device sharing our bus: command "22 01 40 07 00 00 00 6A", ack
  -- "A2 01 01 00 00 00 00 A4". This is a one-shot button-press command,
  -- not a stateful on/off - there is no persistent "elevator state" to
  -- read back (the follow-up "23/A3" status pair repeats regardless of
  -- call/arrival and its meaning is unconfirmed, so it is NOT parsed).
  -- Up-call is NOT implemented - untested (the bridge device used to
  -- confirm this had no up-call option in its own app), so its payload
  -- bytes are unknown and must not be guessed.
  --
  -- CONFIRMED HEADER COLLISION (2026-09-17, real capture): this home also
  -- has a batch light on/off ("일괄소등/점등") switch on the same bus,
  -- using the SAME 0x22/0xA2 header:
  --   batch OFF: cmd "22 01 00 01 00 00 00 24", ack "A2 00 01 00 00 00 00 A3"
  --   batch ON:  cmd "22 01 01 01 00 00 00 25", ack "A2 01 01 00 00 00 00 A4"
  -- The batch-ON ack is BYTE-FOR-BYTE IDENTICAL to the elevator down-call
  -- ack below (same checksum too) - there is no protocol-level way to tell
  -- them apart from the ack alone. This is a real ambiguity in the wallpad
  -- protocol itself, not a parsing bug we can fix. Practical impact: if
  -- someone presses batch-ON while ew11.lua is still waiting for the
  -- elevator ack, the TX queue may treat the call as acknowledged one
  -- retry early. Harmless in practice since the down-call is already sent
  -- twice per press (see handle_elevator_call_down), and elevator_call_ack
  -- is never mapped to a SmartThings device event either way. Batch
  -- on/off is intentionally NOT implemented as a device (not requested).
  CMD_ELEVATOR_CALL_DOWN = { 0x22, 0x01, 0x40, 0x07, 0x00, 0x00, 0x00 },
  ACK_ELEVATOR_CALL_DOWN = { 0xA2, 0x01, 0x01 },
}

--- Calculate 8-bit sum checksum for bytes 1..7
function protocol.calculate_checksum(bytes)
  local sum = 0
  for i = 1, 7 do
    sum = (sum + bytes[i]) & 0xFF
  end
  return sum
end

--- Coerce a value into a valid packet byte (0..255). Never trust callers -
--- command args (SmartThings capability args) or a failed tonumber() can
--- hand us nil or an out-of-range number, and string.char() throws on
--- either, which would otherwise crash the whole TX queue. Invalid input
--- becomes 0x00 rather than raising.
local function to_byte(v)
  if type(v) ~= "number" then return 0 end
  v = math.floor(v)
  if v < 0 or v > 255 then return 0 end
  return v
end

--- Build an 8-byte Commax packet from 7 payload bytes
function protocol.build_packet(b1, b2, b3, b4, b5, b6, b7)
  local payload = { to_byte(b1), to_byte(b2), to_byte(b3), to_byte(b4), to_byte(b5), to_byte(b6), to_byte(b7) }
  local cs = protocol.calculate_checksum(payload)
  payload[8] = cs

  local chars = {}
  for i = 1, 8 do
    chars[i] = string.char(payload[i])
  end
  return table.concat(chars)
end

--- Format byte array/string to uppercase Hex string for logging
function protocol.to_hex(str)
  local t = {}
  for i = 1, #str do
    table.insert(t, string.format("%02X", string.byte(str, i)))
  end
  return table.concat(t, " ")
end

-- =========================================================================
-- Packet Builders
-- =========================================================================

--- Build Light Command (ON / OFF)
--- Packet: [0x31, ID, (ON=1, OFF=0), 0x00, 0x00, 0x00, 0x00, Checksum]
function protocol.build_light_command(id, is_on)
  local pwr = is_on and 0x01 or 0x00
  return protocol.build_packet(protocol.CMD_LIGHT, id, pwr, 0x00, 0x00, 0x00, 0x00)
end

--- Build Light Status Query
--- Packet: [0x30, ID, 0x00, 0x00, 0x00, 0x00, 0x00, Checksum]
--- Confirmed by real EW11 capture 2026-09-16 (see REQ_LIGHT comment above).
function protocol.build_light_query(id)
  return protocol.build_packet(protocol.REQ_LIGHT, id, 0x00, 0x00, 0x00, 0x00, 0x00)
end

--- Build Thermostat Power Command (Heat / Off)
--- Packet: [0x04, ID, 0x04, (Heat=0x81, Off=0x00), 0x00, 0x00, 0x00, Checksum]
function protocol.build_thermostat_power(id, is_heat)
  local pwr = is_heat and 0x81 or 0x00
  return protocol.build_packet(protocol.CMD_THERMO, id, 0x04, pwr, 0x00, 0x00, 0x00)
end

--- Build Thermostat Target Temperature Command
--- Packet: [0x04, ID, 0x03, BCD(temp), 0x00, 0x00, 0x00, Checksum]
function protocol.build_thermostat_temperature(id, temp)
  local bcd_temp = bcd.encode(temp)
  return protocol.build_packet(protocol.CMD_THERMO, id, 0x03, bcd_temp, 0x00, 0x00, 0x00)
end

--- Build Thermostat State Query
--- Packet: [0x02, ID, 0x00, 0x00, 0x00, 0x00, 0x00, Checksum]
function protocol.build_thermostat_query(id)
  return protocol.build_packet(protocol.REQ_THERMO, id, 0x00, 0x00, 0x00, 0x00, 0x00)
end

--- Build Ventilation Fan Power Command
--- Packet: [0x78, ID, 0x01, (ON=0x04, OFF=0x00), 0x00, 0x00, 0x00, Checksum]
function protocol.build_fan_power(id, is_on)
  local pwr = is_on and 0x04 or 0x00
  return protocol.build_packet(protocol.CMD_FAN, id, 0x01, pwr, 0x00, 0x00, 0x00)
end

--- Build Ventilation Fan Speed Command (1: Low, 2: Med, 3: High)
--- Packet: [0x78, ID, 0x02, speed, 0x00, 0x00, 0x00, Checksum]
function protocol.build_fan_speed(id, speed)
  if type(speed) ~= "number" then speed = 1 end
  speed = math.max(1, math.min(3, math.floor(speed)))
  return protocol.build_packet(protocol.CMD_FAN, id, 0x02, speed, 0x00, 0x00, 0x00)
end

--- Build Gas Valve Close Command
--- Packet: [0x11, 0x01, 0x80, 0x00, 0x00, 0x00, 0x00, 0x92]
function protocol.build_gas_close()
  return protocol.build_packet(protocol.CMD_GAS, 0x01, 0x80, 0x00, 0x00, 0x00, 0x00)
end

--- Build Outlet Command (ON / OFF)
--- Packet: [0x7A, ID, 0x01, (ON=1, OFF=0), 0x00, 0x00, 0x00, Checksum]
--- CONFIRMED 2026-09-17 by real capture (see CMD_OUTLET comment above).
function protocol.build_outlet_command(id, is_on)
  local pwr = is_on and 0x01 or 0x00
  return protocol.build_packet(protocol.CMD_OUTLET, id, 0x01, pwr, 0x00, 0x00, 0x00)
end

--- Build Outlet Status Query
--- Packet: [0x79, ID, 0x01, 0x00, 0x00, 0x00, 0x00, Checksum]
function protocol.build_outlet_query(id)
  return protocol.build_packet(protocol.REQ_OUTLET, id, 0x01, 0x00, 0x00, 0x00, 0x00)
end

--- Build Elevator Down-Call Command
--- Packet: [0x22, 0x01, 0x40, 0x07, 0x00, 0x00, 0x00, Checksum]
--- CONFIRMED 2026-09-17 by real capture (see CMD_ELEVATOR_CALL_DOWN comment above).
function protocol.build_elevator_call_down()
  local p = protocol.CMD_ELEVATOR_CALL_DOWN
  return protocol.build_packet(p[1], p[2], p[3], p[4], p[5], p[6], p[7])
end

-- =========================================================================
-- ACK Prefix Builders
-- =========================================================================
-- Each command in the reference source (homenet2mqtt gallery/commax/*.yaml)
-- declares an explicit `ack:` byte prefix that the bridge waits for after
-- sending. These are used by ew11.lua's TX queue to confirm a command was
-- actually received by the wallpad (RS485 is a shared half-duplex bus, so
-- writes can be dropped/collided without this). Only prefixes that are
-- literally present in the source YAML are defined here.

--- ack: [0xB1, ON, ID] - lights_new.yaml
function protocol.ack_light_command(id, is_on)
  local pwr = is_on and 0x01 or 0x00
  return { protocol.ACK_LIGHT, pwr, id }
end

--- ack: [0x84, 0x81, ID] (heat) / [0x84, 0x80, ID] (off) - heaters_new.yaml
--- NOTE: the OFF command's payload byte is 0x00, but its ack byte is 0x80 -
--- these are two different values, both confirmed from the source YAML.
function protocol.ack_thermostat_power(id, is_heat)
  local ack_pwr = is_heat and 0x81 or 0x80
  return { protocol.ACK_THERMO, ack_pwr, id }
end

--- ack: [0x84, 0x00, ID] - heaters_new.yaml command_temperature
function protocol.ack_thermostat_temperature(id)
  return { protocol.ACK_THERMO, 0x00, id }
end

--- ack: [0xF8, 0x04] - fan_new.yaml command_on / command_speed
function protocol.ack_fan_on()
  return { protocol.ACK_FAN, 0x04 }
end

--- ack: [0xF8, 0x00] - fan_new.yaml command_off
function protocol.ack_fan_off()
  return { protocol.ACK_FAN, 0x00 }
end

--- ack: [0xF8, 0x04] - fan_new.yaml command_speed (same ack as command_on)
function protocol.ack_fan_speed()
  return { protocol.ACK_FAN, 0x04 }
end

--- ack: [0x91, 0x88, 0x88] - gas_valve.yaml command_close
function protocol.ack_gas_close()
  return { protocol.ACK_GAS, 0x88, 0x88 }
end

--- ack: [0xFA, 0x11, ID] (ON) / [0xFA, 0x10, ID] (OFF)
--- CONFIRMED 2026-09-17 by real capture (see CMD_OUTLET comment above).
function protocol.ack_outlet_command(id, is_on)
  local ack_pwr = is_on and protocol.OUTLET_ON or protocol.OUTLET_OFF
  return { protocol.ACK_OUTLET, ack_pwr, id }
end

--- ack: [0xA2, 0x01, 0x01] - CONFIRMED 2026-09-17 by real capture.
function protocol.ack_elevator_call_down()
  local a = protocol.ACK_ELEVATOR_CALL_DOWN
  return { a[1], a[2], a[3] }
end

-- =========================================================================
-- Packet Parser
-- =========================================================================

--- Parse an 8-byte Commax packet into structured status
function protocol.parse_packet(raw_bytes)
  if #raw_bytes ~= 8 then return nil, "Invalid length" end
  
  local b = {}
  for i = 1, 8 do
    b[i] = string.byte(raw_bytes, i)
  end
  
  local expected_cs = protocol.calculate_checksum(b)
  if expected_cs ~= b[8] then
    return nil, string.format("Checksum mismatch: got 0x%02X, expected 0x%02X", b[8], expected_cs)
  end

  local head = b[1]

  -- 1. Light State (0xB0) or Light ACK (0xB1)
  -- Packet: [Head, Power(0/1), ID, 0x00, 0x00, 0x00, 0x00, CS]
  if head == protocol.STATE_LIGHT or head == protocol.ACK_LIGHT then
    local is_on = (b[2] == 0x01)
    local light_id = b[3]
    return {
      device_type = "light",
      id = light_id,
      is_on = is_on,
      raw = raw_bytes
    }

  -- 2. Thermostat State (0x82) or ACK (0x84)
  -- Packet: [Head, Power/Mode, ID, CurTemp(BCD), TarTemp(BCD), 0x00, 0x00, CS]
  -- Source: gallery/commax/heaters_new.yaml
  elseif head == protocol.STATE_THERMO or head == protocol.ACK_THERMO then
    local pwr_code = b[2]
    local thermo_id = b[3]
    local cur_temp = bcd.decode(b[4])
    local target_temp = bcd.decode(b[5])

    local mode = "off"
    local state = "idle"
    if pwr_code == protocol.THERMO_HEAT_IDLE then
      mode = "heat"
      state = "idle"
    elseif pwr_code == protocol.THERMO_HEATING then
      mode = "heat"
      state = "heating"
    elseif pwr_code == protocol.THERMO_OFF then
      mode = "off"
      state = "idle"
    end

    return {
      device_type = "thermostat",
      id = thermo_id,
      mode = mode,
      state = state,
      current_temperature = cur_temp,
      target_temperature = target_temp,
      raw = raw_bytes
    }

  -- 3. Ventilation Fan State (mask 0xF1 == 0xF0, e.g. 0xF0/0xF6/...) or ACK (0xF8)
  -- Packet: [Head, Power, ID, Speed, 0x00, 0x00, 0x00, CS]
  -- Source: gallery/commax/fan_new.yaml entities.fan (actual match/mask logic,
  -- not the inconsistent description-table comment in the same file)
  -- NOTE: the outlet ACK header (0xFA) also happens to satisfy this bit
  -- mask (0xFA & 0xF1 == 0xF0) - explicitly excluded here since outlet
  -- state/ack (0xF9/0xFA) are confirmed, exact, unrelated headers.
  elseif (head ~= protocol.STATE_OUTLET and head ~= protocol.ACK_OUTLET)
      and ((head & protocol.STATE_FAN_MASK) == protocol.STATE_FAN_VALUE or head == protocol.ACK_FAN) then
    local pwr_byte = b[2]
    local fan_id = b[3]
    local speed = b[4]
    local is_on = (pwr_byte ~= 0x00)

    return {
      device_type = "fan",
      id = fan_id,
      is_on = is_on,
      speed = speed,
      raw = raw_bytes
    }

  -- 4. Gas Valve State (0x90) or ACK (0x91)
  -- Packet: [Head, Status, StatusRepeat, 0x00, 0x00, 0x00, 0x00, CS]
  -- CLOSED (0x50) confirmed by real capture; OPEN (0xA0) not directly
  -- observed - see the constant comments above. Regardless of which value
  -- is right, is_open is fail-safe: anything other than exactly GAS_OPEN
  -- is treated as closed, so an unrecognized byte never falsely reports open.
  elseif head == protocol.STATE_GAS or head == protocol.ACK_GAS then
    local status = b[2]
    local is_open = (status == protocol.GAS_OPEN)
    return {
      device_type = "gas",
      id = 1,
      is_open = is_open,
      raw = raw_bytes
    }

  -- 5. CO2 Sensor (0xF7 0x82 0x01 ...) - read-only, no command exists
  -- Packet: [0xF7, 0x82, 0x01, 0x00, 0x1A, CO2_hi(BCD), CO2_lo(BCD), CS]
  -- CONFIRMED 2026-09-17 by real EW11 capture matched live against the
  -- wallpad display (see HEAD_CO2 comment above).
  elseif head == protocol.HEAD_CO2 and b[2] == protocol.CO2_SUB1 and b[3] == protocol.CO2_SUB2 then
    return {
      device_type = "co2",
      id = 1,
      ppm = bcd.decode_word(b[6], b[7]),
      raw = raw_bytes
    }

  -- 6. Dust Sensor: PM2.5 (0xC8 0x31 0x01 ...) / PM10 (0xC8 0x3F 0x01 ...)
  -- Packet: [0xC8, sub, 0x01, ?, ?, PM_hi(BCD), PM_lo(BCD), CS]
  -- CONFIRMED 2026-09-17 the same way as CO2 above.
  elseif head == protocol.HEAD_DUST and b[3] == protocol.DUST_SUB2
      and (b[2] == protocol.DUST_PM25 or b[2] == protocol.DUST_PM10) then
    return {
      device_type = (b[2] == protocol.DUST_PM25) and "pm25" or "pm10",
      id = 1,
      ug_m3 = bcd.decode_word(b[6], b[7]),
      raw = raw_bytes
    }

  -- 7. Outlet State (0xF9) or ACK (0xFA)
  -- Packet: [Head, Power(0x10=OFF/0x11=ON), ID, Attr, 0x00, 0x00, ?, CS]
  -- CONFIRMED 2026-09-17 by real capture (see CMD_OUTLET comment above).
  elseif head == protocol.STATE_OUTLET or head == protocol.ACK_OUTLET then
    local is_on = (b[2] == protocol.OUTLET_ON)
    return {
      device_type = "outlet",
      id = b[3],
      is_on = is_on,
      raw = raw_bytes
    }

  -- 8. Elevator Down-Call ACK (0xA2 0x01 0x01) - no persistent state exists
  -- for this device (momentary call only), so this only exists to let
  -- ew11.lua's TX queue recognize the ACK and stop retrying; it is not
  -- mapped to any SmartThings device event.
  elseif head == protocol.ACK_ELEVATOR_CALL_DOWN[1] and b[2] == protocol.ACK_ELEVATOR_CALL_DOWN[2]
      and b[3] == protocol.ACK_ELEVATOR_CALL_DOWN[3] then
    return {
      device_type = "elevator_call_ack",
      raw = raw_bytes
    }
  end

  return nil, "Unknown packet header: " .. string.format("0x%02X", head)
end

return protocol
