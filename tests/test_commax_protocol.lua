-- =========================================================================
-- Commax Protocol Offline Unit Test Suite
-- =========================================================================
local bcd = require("bcd")
local protocol = require("commax_protocol")

local function assert_hex(expected_hex, actual_str, desc)
  local expected = expected_hex:gsub("%s+", ""):upper()
  local actual = ""
  for i = 1, #actual_str do
    actual = actual .. string.format("%02X", string.byte(actual_str, i))
  end
  if expected == actual then
    print(string.format("[PASS] %s: %s", desc, actual))
  else
    error(string.format("[FAIL] %s\nExpected: %s\nGot:      %s", desc, expected, actual))
  end
end

print("=== Starting Commax Protocol Unit Tests ===")

-- 1. BCD Tests
assert(bcd.encode(25) == 0x25, "BCD encode 25 should be 0x25")
assert(bcd.decode(0x25) == 25, "BCD decode 0x25 should be 25")
assert(bcd.encode(5) == 0x05, "BCD encode 5 should be 0x05")
assert(bcd.decode(0x05) == 5, "BCD decode 0x05 should be 5")
assert(bcd.decode_word(0x13, 0x13) == 1313, "BCD decode_word(0x13,0x13) should be 1313")
assert(bcd.decode_word(0x00, 0x01) == 1, "BCD decode_word(0x00,0x01) should be 1")
print("[PASS] BCD Encode/Decode")

-- 1b. BCD with invalid (non-BCD, nibble > 9) input bytes. bcd.decode() does
-- not validate that each nibble is 0-9 - it just does (tens*10 + ones)
-- arithmetic on whatever nibbles are present. This is current, deliberate
-- behavior (not a bug to fix here - see QA review): parse_packet's
-- checksum check is the actual guard against corrupted bytes reaching BCD
-- fields at all, so this test only pins down what bcd.decode() itself does
-- with an out-of-range nibble, as a regression guard against a future
-- change silently altering this (e.g. by adding validation that throws).
assert(bcd.decode(0x00) == 0, "BCD decode 0x00 should be 0")
assert(bcd.decode(0x09) == 9, "BCD decode 0x09 should be 9")
assert(bcd.decode(0x99) == 99, "BCD decode 0x99 should be 99")
assert(bcd.decode(0x0A) == 10, "BCD decode of invalid nibble 0x0A (tens=0,ones=10) computes 0*10+10=10, not an error")
assert(bcd.decode(0xAF) == 115, "BCD decode of invalid nibbles 0xAF (tens=10,ones=15) computes 10*10+15=115, not an error")
assert(bcd.decode(0xFF) == 165, "BCD decode of invalid nibbles 0xFF (tens=15,ones=15) computes 15*10+15=165, not an error")
assert(bcd.decode("not a number") == 0, "BCD decode of a non-numeric input returns 0, not an error")
print("[PASS] BCD invalid-nibble input does not throw (known limitation: no nibble range validation)")

-- 2. Light Command Packets (Ground truth from homenet2mqtt / commax.test.ts)
local light1_on = protocol.build_light_command(1, true)
assert_hex("31 01 01 00 00 00 00 33", light1_on, "Light 1 ON")

local light1_off = protocol.build_light_command(1, false)
assert_hex("31 01 00 00 00 00 00 32", light1_off, "Light 1 OFF")

local light2_on = protocol.build_light_command(2, true)
assert_hex("31 02 01 00 00 00 00 34", light2_on, "Light 2 ON")

-- Light query: CONFIRMED 2026-09-16 by real EW11 capture ("30 01 00 00 00 00 00 31")
local light1_query = protocol.build_light_query(1)
assert_hex("30 01 00 00 00 00 00 31", light1_query, "Light 1 Query (real-capture-confirmed)")

-- 3. Thermostat Command Packets
local thermo1_heat = protocol.build_thermostat_power(1, true)
assert_hex("04 01 04 81 00 00 00 8A", thermo1_heat, "Thermo 1 Heat (Power ON)")

local thermo1_off = protocol.build_thermostat_power(1, false)
assert_hex("04 01 04 00 00 00 00 09", thermo1_off, "Thermo 1 Off")

local thermo1_temp25 = protocol.build_thermostat_temperature(1, 25)
assert_hex("04 01 03 25 00 00 00 2D", thermo1_temp25, "Thermo 1 Set Temp 25C (commax.test.ts exact match)")

-- 4. Fan Command Packets
local fan_on = protocol.build_fan_power(1, true)
assert_hex("78 01 01 04 00 00 00 7E", fan_on, "Fan 1 Power ON")

local fan_speed1 = protocol.build_fan_speed(1, 1)
assert_hex("78 01 02 01 00 00 00 7C", fan_speed1, "Fan 1 Speed 1 (commax.test.ts exact match)")

-- 5. Gas Command Packet
local gas_close = protocol.build_gas_close()
assert_hex("11 01 80 00 00 00 00 92", gas_close, "Gas Valve Close")

-- 5a. Outlet Command Packets
-- CONFIRMED 2026-09-17 by real command/ack/state correlation: toggling
-- outlet 1 OFF then ON produced exactly these bytes on the bus.
local outlet1_off = protocol.build_outlet_command(1, false)
assert_hex("7A 01 01 00 00 00 00 7C", outlet1_off, "Outlet 1 OFF (real-capture-confirmed)")

local outlet1_on = protocol.build_outlet_command(1, true)
assert_hex("7A 01 01 01 00 00 00 7D", outlet1_on, "Outlet 1 ON (real-capture-confirmed)")

local outlet1_query = protocol.build_outlet_query(1)
assert_hex("79 01 01 00 00 00 00 7B", outlet1_query, "Outlet 1 Query (real-capture-confirmed)")

-- 5c. Elevator Down-Call Command
-- CONFIRMED 2026-09-17 by real capture while calling the elevator down
-- via a separate RS485-to-Matter bridge sharing our bus.
local elevator_call = protocol.build_elevator_call_down()
assert_hex("22 01 40 07 00 00 00 6A", elevator_call, "Elevator Down-Call (real-capture-confirmed)")

-- 5b. ACK Prefix Builders (used by ew11.lua's TX retry queue)
local function assert_ack(expected, actual, desc)
  assert(#expected == #actual, desc .. " (length mismatch)")
  for i = 1, #expected do
    assert(expected[i] == actual[i], string.format("%s (byte %d mismatch: expected 0x%02X got 0x%02X)", desc, i, expected[i], actual[i]))
  end
  print(string.format("[PASS] %s", desc))
end

assert_ack({0xB1, 0x01, 0x01}, protocol.ack_light_command(1, true), "ACK Light 1 ON")
assert_ack({0xB1, 0x00, 0x01}, protocol.ack_light_command(1, false), "ACK Light 1 OFF")
assert_ack({0x84, 0x81, 0x01}, protocol.ack_thermostat_power(1, true), "ACK Thermo 1 Heat")
assert_ack({0x84, 0x80, 0x01}, protocol.ack_thermostat_power(1, false), "ACK Thermo 1 Off")
assert_ack({0x84, 0x00, 0x01}, protocol.ack_thermostat_temperature(1), "ACK Thermo 1 Set Temp")
assert_ack({0xF8, 0x04}, protocol.ack_fan_on(), "ACK Fan ON")
assert_ack({0xF8, 0x00}, protocol.ack_fan_off(), "ACK Fan OFF")
assert_ack({0xF8, 0x04}, protocol.ack_fan_speed(), "ACK Fan Speed")
assert_ack({0x91, 0x88, 0x88}, protocol.ack_gas_close(), "ACK Gas Close")
assert_ack({0xFA, 0x10, 0x01}, protocol.ack_outlet_command(1, false), "ACK Outlet 1 OFF")
assert_ack({0xFA, 0x11, 0x01}, protocol.ack_outlet_command(1, true), "ACK Outlet 1 ON")
assert_ack({0xA2, 0x01, 0x01}, protocol.ack_elevator_call_down(), "ACK Elevator Down-Call")

-- 6. Packet Parsing Tests
local function hex_to_bin(hex_str)
  local clean = hex_str:gsub("%s+", "")
  local t = {}
  for i = 1, #clean, 2 do
    local byte_val = tonumber(clean:sub(i, i + 1), 16)
    table.insert(t, string.char(byte_val))
  end
  return table.concat(t)
end

-- Light 1 State ON: B0 01 01 00 00 00 00 B2
local light_state_pkt = hex_to_bin("B0 01 01 00 00 00 00 B2")
local res_light, err_l = protocol.parse_packet(light_state_pkt)
assert(res_light and res_light.device_type == "light", "Parse light state")
assert(res_light.id == 1 and res_light.is_on == true, "Light 1 state should be ON")
print("[PASS] Parse Light State (ON)")

-- Thermo 1 State (Temp 22C, Target 25C, Heating): 82 83 01 22 25 00 00 4D
-- Header 0x82 (state), payload[2]=0x83 (heating). Source: heaters_new.yaml
local thermo_state_pkt = hex_to_bin("82 83 01 22 25 00 00 4D")
local res_thermo, err_t = protocol.parse_packet(thermo_state_pkt)
assert(res_thermo and res_thermo.device_type == "thermostat", "Parse thermo state")
assert(res_thermo.current_temperature == 22, "Current temperature 22C")
assert(res_thermo.target_temperature == 25, "Target temperature 25C")
assert(res_thermo.state == "heating", "Heating state active")
print("[PASS] Parse Thermostat State (Heating, 22C -> 25C)")

-- Gas State CLOSED: 90 50 50 00 00 00 00 30
-- CONFIRMED 2026-09-16 by real EW11 capture (tools/capture_ew11.ps1) -
-- our home's wallpad broadcasts exactly this while the valve is closed.
local gas_state_pkt = hex_to_bin("90 50 50 00 00 00 00 30")
local res_gas, err_g = protocol.parse_packet(gas_state_pkt)
assert(res_gas and res_gas.device_type == "gas", "Parse gas state")
assert(res_gas.is_open == false, "Gas valve should be CLOSED")
print("[PASS] Parse Gas Valve State (CLOSED, real-capture-confirmed byte 0x50)")

-- Gas State OPEN: 90 A0 A0 00 00 00 00 D0
-- NOT directly observed on our bus (valve was never opened during
-- capture) - taken from kimtc99/HAaddons, the same source that correctly
-- predicted our real CLOSED byte above. See commax_protocol.lua GAS_OPEN
-- comment; still flagged as 정보 불충분 in README until directly observed.
local gas_open_pkt = hex_to_bin("90 A0 A0 00 00 00 00 D0")
local res_gas_open, err_go = protocol.parse_packet(gas_open_pkt)
assert(res_gas_open and res_gas_open.device_type == "gas", "Parse gas state (open)")
assert(res_gas_open.is_open == true, "Gas valve should be OPEN")
print("[PASS] Parse Gas Valve State (OPEN, unconfirmed byte 0xA0)")

-- Old (superseded) homenet2mqtt-sourced gas bytes must now be treated as
-- CLOSED under the corrected constants, proving we didn't just widen the
-- "open" check - the old open-byte no longer matches.
local old_open_guess_pkt = hex_to_bin("90 80 80 00 00 00 00 90")
local res_old, err_old = protocol.parse_packet(old_open_guess_pkt)
assert(res_old and res_old.device_type == "gas" and res_old.is_open == false,
  "Superseded homenet2mqtt open-byte (0x80) must now read as closed, not open")
print("[PASS] Parse Gas Valve State (superseded 0x80 byte now correctly reads as CLOSED)")

-- CO2 Sensor: F7 82 01 00 1A 13 13 BA
-- CONFIRMED 2026-09-17 by real EW11 capture matched live against the
-- wallpad display showing CO2=1313, then tracked live as it fell to
-- 1235/1223/1221 with matching trailing bytes each time.
local co2_pkt = hex_to_bin("F7 82 01 00 1A 13 13 BA")
local res_co2, err_co2 = protocol.parse_packet(co2_pkt)
assert(res_co2 and res_co2.device_type == "co2", "Parse CO2 sensor packet")
assert(res_co2.ppm == 1313, "CO2 should be 1313 ppm")
print("[PASS] Parse CO2 Sensor (1313 ppm, real-capture-confirmed)")

-- CO2 Sensor, ALT sub-byte 0x80 (not 0x82): F7 80 01 00 1B 07 54 EE
-- CONFIRMED 2026-09-22 by real EW11 capture: this household's wallpad
-- broadcasts CO2 with sub-byte 0x80, not 0x82 - without matching this,
-- CO2 silently stopped updating (see CO2_SUB1_ALT comment in
-- commax_protocol.lua).
local co2_alt_pkt = hex_to_bin("F7 80 01 00 1B 07 54 EE")
local res_co2_alt = protocol.parse_packet(co2_alt_pkt)
assert(res_co2_alt and res_co2_alt.device_type == "co2", "Parse CO2 sensor packet (0x80 alt sub-byte)")
assert(res_co2_alt.ppm == 754, "CO2 (alt) should be 754 ppm")
print("[PASS] Parse CO2 Sensor, alt sub-byte 0x80 (754 ppm, real-capture-confirmed)")

-- PM2.5 Sensor: C8 11 01 04 88 00 01 67
-- Value byte position CORRECTED 2026-09-26 back to bytes 6-7 ("00 01" = 1)
-- after a live side-by-side check against the wallpad's own PM2.5 display
-- (see commax_protocol.lua DUST_PM25 comment for the full story - the
-- 2026-09-19 move to bytes 4-5 had it backwards).
local pm25_pkt = hex_to_bin("C8 11 01 04 88 00 01 67")
local res_pm25, err_pm25 = protocol.parse_packet(pm25_pkt)
assert(res_pm25 and res_pm25.device_type == "pm25", "Parse PM2.5 sensor packet")
assert(res_pm25.ug_m3 == 1, "PM2.5 should be 1 (BCD bytes 6-7)")
print("[PASS] Parse PM2.5 Sensor (1, real-capture-corrected)")

-- PM10 Sensor: C8 1F 01 04 88 00 01 75
-- Same byte-position correction as PM2.5 above. PM2.5-vs-PM10 assignment
-- between 0x11/0x1F is still unverified - see comment in commax_protocol.lua
-- (though PM10 is no longer exposed by this driver - no physical sensor).
local pm10_pkt = hex_to_bin("C8 1F 01 04 88 00 01 75")
local res_pm10, err_pm10 = protocol.parse_packet(pm10_pkt)
assert(res_pm10 and res_pm10.device_type == "pm10", "Parse PM10 sensor packet")
assert(res_pm10.ug_m3 == 1, "PM10 should be 1 (BCD bytes 6-7)")
print("[PASS] Parse PM10 Sensor (1, real-capture-corrected)")

-- PM2.5/PM10 sub-byte ALT variant (0x21/0x2F instead of 0x11/0x1F) -
-- CONFIRMED 2026-09-22 by a real 90s capture from this project's own EW11:
-- this household's wallpad uses 0x21/0x2F, not 0x11/0x1F, and without
-- matching this variant the parser fell through to "Unknown packet
-- header", leaving PM2.5/PM10 permanently NaN in SmartThings.
local pm25_alt_pkt = hex_to_bin("C8 21 01 07 66 00 01 58")
local res_pm25_alt = protocol.parse_packet(pm25_alt_pkt)
assert(res_pm25_alt and res_pm25_alt.device_type == "pm25", "Parse PM2.5 sensor packet (0x21 alt sub-byte)")
assert(res_pm25_alt.ug_m3 == 1, "PM2.5 (alt) should be 1 (BCD bytes 6-7)")
print("[PASS] Parse PM2.5 Sensor, alt sub-byte 0x21 (1, real-capture-confirmed)")

local pm10_alt_pkt = hex_to_bin("C8 2F 01 07 66 00 01 66")
local res_pm10_alt = protocol.parse_packet(pm10_alt_pkt)
assert(res_pm10_alt and res_pm10_alt.device_type == "pm10", "Parse PM10 sensor packet (0x2F alt sub-byte)")
assert(res_pm10_alt.ug_m3 == 1, "PM10 (alt) should be 1 (BCD bytes 6-7)")
print("[PASS] Parse PM10 Sensor, alt sub-byte 0x2F (1, real-capture-confirmed)")

-- PM2.5, fresh 2026-09-26 capture: C8 11 01 05 00 00 01 E0 - CONFIRMED
-- live against the wallpad's own display, which showed PM2.5=1 at the
-- exact same moment. This is the packet that proved bytes 4-5 (05 00 ->
-- 500) was the wrong field and bytes 6-7 (00 01 -> 1) is correct.
local pm25_fresh_pkt = hex_to_bin("C8 11 01 05 00 00 01 E0")
local res_pm25_fresh = protocol.parse_packet(pm25_fresh_pkt)
assert(res_pm25_fresh and res_pm25_fresh.device_type == "pm25", "Parse PM2.5 sensor packet (2026-09-26 fresh capture)")
assert(res_pm25_fresh.ug_m3 == 1, "PM2.5 should be 1, matching the wallpad's own display at capture time")
print("[PASS] Parse PM2.5 Sensor, 2026-09-26 fresh capture (1, wallpad-display-confirmed)")

-- Outlet State: F9 10 01 10 00 00 00 1A (OFF) / F9 11 01 10 00 00 00 1B (ON)
-- CONFIRMED 2026-09-17 by real command/ack/state correlation on our bus.
local outlet_off_pkt = hex_to_bin("F9 10 01 10 00 00 00 1A")
local res_outlet_off, err_outlet_off = protocol.parse_packet(outlet_off_pkt)
assert(res_outlet_off and res_outlet_off.device_type == "outlet", "Parse outlet state")
assert(res_outlet_off.id == 1 and res_outlet_off.is_on == false, "Outlet 1 state should be OFF")
print("[PASS] Parse Outlet State (OFF, real-capture-confirmed)")

local outlet_on_pkt = hex_to_bin("F9 11 01 10 00 00 00 1B")
local res_outlet_on, err_outlet_on = protocol.parse_packet(outlet_on_pkt)
assert(res_outlet_on and res_outlet_on.device_type == "outlet", "Parse outlet state")
assert(res_outlet_on.id == 1 and res_outlet_on.is_on == true, "Outlet 1 state should be ON")
print("[PASS] Parse Outlet State (ON, real-capture-confirmed)")

-- Outlet ACK: FA 10 01 10 00 00 00 1B (OFF ack) / FA 11 01 10 00 00 00 1C (ON ack)
local outlet_ack_off_pkt = hex_to_bin("FA 10 01 10 00 00 00 1B")
local res_outlet_ack_off = protocol.parse_packet(outlet_ack_off_pkt)
assert(res_outlet_ack_off and res_outlet_ack_off.device_type == "outlet" and res_outlet_ack_off.is_on == false,
  "Outlet 1 ACK should parse as OFF")
print("[PASS] Parse Outlet ACK (OFF, real-capture-confirmed)")

-- Elevator Down-Call ACK: A2 01 01 00 00 00 00 A4
-- Recognized only so ew11.lua's TX retry queue can detect it - not mapped
-- to any SmartThings device event (momentary, no persistent state).
local elevator_ack_pkt = hex_to_bin("A2 01 01 00 00 00 00 A4")
local res_elevator_ack = protocol.parse_packet(elevator_ack_pkt)
assert(res_elevator_ack and res_elevator_ack.device_type == "elevator_call_ack",
  "Parse elevator down-call ACK")
print("[PASS] Parse Elevator Down-Call ACK (real-capture-confirmed)")

-- Fan State ON, ID 1, Speed 2: F6 01 01 02 00 00 00 FA
-- Header 0xF6 matches the (byte & 0xF1) == 0xF0 family used by the real
-- entities.fan discovery logic in fan_new.yaml.
local fan_state_pkt = hex_to_bin("F6 01 01 02 00 00 00 FA")
local res_fan, err_f = protocol.parse_packet(fan_state_pkt)
assert(res_fan and res_fan.device_type == "fan", "Parse fan state")
assert(res_fan.id == 1 and res_fan.is_on == true and res_fan.speed == 2, "Fan 1 should be ON at speed 2")
print("[PASS] Parse Fan State (ON, speed 2)")

-- Fan ON/speed/mode CONFIRMED 2026-09-17 by real capture (see CMD_FAN comment)
local fan_hx1 = hex_to_bin("F6 04 01 01 00 00 00 FC") -- 전열, speed 1
local res_hx1 = protocol.parse_packet(fan_hx1)
assert(res_hx1.is_on == true and res_hx1.speed == 1, "Fan 전열 speed 1 should be ON, speed 1")
print("[PASS] Parse Fan State (전열/heat-exchange, speed 1, real-capture-confirmed)")

local fan_hx3 = hex_to_bin("F6 04 01 03 00 00 00 FE") -- 전열, speed 3
local res_hx3 = protocol.parse_packet(fan_hx3)
assert(res_hx3.is_on == true and res_hx3.speed == 3, "Fan 전열 speed 3 should be ON, speed 3")
print("[PASS] Parse Fan State (전열/heat-exchange, speed 3, real-capture-confirmed)")

local fan_bypass = hex_to_bin("F6 07 01 03 00 00 00 01") -- 바이패스, speed 3
local res_bypass = protocol.parse_packet(fan_bypass)
assert(res_bypass.is_on == true and res_bypass.speed == 3, "Fan 바이패스 should still parse as ON")
print("[PASS] Parse Fan State (바이패스/bypass, real-capture-confirmed)")

local fan_auto = hex_to_bin("F6 02 01 01 00 00 00 FA") -- 자동, speed 1
local res_auto = protocol.parse_packet(fan_auto)
assert(res_auto.is_on == true and res_auto.speed == 1, "Fan 자동 should still parse as ON")
print("[PASS] Parse Fan State (자동/auto, real-capture-confirmed)")

-- Thermostat state HEAT (idle, not actively heating): 82 81 01 22 25 00 00 4B
local thermo_idle_pkt = hex_to_bin("82 81 01 22 25 00 00 4B")
local res_thermo_idle, err_ti = protocol.parse_packet(thermo_idle_pkt)
assert(res_thermo_idle and res_thermo_idle.mode == "heat" and res_thermo_idle.state == "idle", "Thermo should be heat/idle")
print("[PASS] Parse Thermostat State (Heat mode, idle)")

-- Thermostat state AWAY: CONFIRMED 2026-09-17 real capture "82 84 02 27 10 00 00 3F"
local thermo_away_pkt = hex_to_bin("82 84 02 27 10 00 00 3F")
local res_thermo_away, err_ta = protocol.parse_packet(thermo_away_pkt)
assert(res_thermo_away and res_thermo_away.mode == "off" and res_thermo_away.state == "idle", "Thermo AWAY should surface as off/idle")
print("[PASS] Parse Thermostat State (Away mode -> off/idle)")

-- Thermostat state RESERVE: CONFIRMED 2026-09-17 real capture "82 00 02 27 15 00 00 C0"
local thermo_reserve_pkt = hex_to_bin("82 00 02 27 15 00 00 C0")
local res_thermo_reserve, err_tr = protocol.parse_packet(thermo_reserve_pkt)
assert(res_thermo_reserve and res_thermo_reserve.mode == "off" and res_thermo_reserve.state == "idle", "Thermo RESERVE should surface as off/idle")
print("[PASS] Parse Thermostat State (Reserve mode -> off/idle)")

-- Elevator status: CONFIRMED 2026-09-17 real capture "23 01 01 04 07 00 00 30"
local elev_status_pkt = hex_to_bin("23 01 01 04 07 00 00 30")
local res_elev_status, err_es = protocol.parse_packet(elev_status_pkt)
assert(res_elev_status and res_elev_status.device_type == "elevator_status" and res_elev_status.status == "called", "Elevator status should be called")
print("[PASS] Parse Elevator Status (0x23, real-capture-confirmed)")

-- 7. Robustness Tests (fault-injection scenarios from the failure-mode
-- review: malformed/garbage input must never crash the parser or builders,
-- since one bad packet/command must not be able to take down the driver)

-- 7a. Invalid length must be rejected, not crash
local ok_len, res_len, err_len = pcall(protocol.parse_packet, hex_to_bin("B0 01 01"))
assert(ok_len, "parse_packet must not throw on short input")
assert(res_len == nil, "parse_packet should return nil for wrong-length input")
print("[PASS] parse_packet rejects short/invalid-length input without throwing")

-- 7b. Checksum mismatch (corrupted byte on the wire) must be rejected, not crash
local corrupt_pkt = hex_to_bin("B0 01 01 00 00 00 00 FF") -- wrong checksum
local res_corrupt, err_corrupt = protocol.parse_packet(corrupt_pkt)
assert(res_corrupt == nil and err_corrupt ~= nil, "Corrupted checksum should be rejected with an error message")
print("[PASS] parse_packet rejects checksum-corrupted packet")

-- 7c. Unknown header (unrecognized device family on the bus) must be
-- rejected gracefully, not crash - e.g. some other RS485 device's traffic.
local checksum_of = function(bytes)
  local sum = 0
  for i = 1, 7 do sum = (sum + bytes[i]) & 0xFF end
  return sum
end
local unknown_bytes = {0xC7, 0x11, 0x22, 0x00, 0x00, 0x00, 0x00}
unknown_bytes[8] = checksum_of(unknown_bytes)
local unknown_chars = {}
for i = 1, 8 do unknown_chars[i] = string.char(unknown_bytes[i]) end
local res_unknown, err_unknown = protocol.parse_packet(table.concat(unknown_chars))
assert(res_unknown == nil and err_unknown ~= nil, "Unknown header should be rejected, not crash")
print("[PASS] parse_packet rejects unknown/unrecognized header")

-- 7d. Builders must not crash on nil/invalid external input (e.g. a
-- malformed SmartThings capability command argument)
local ok_nil_id = pcall(protocol.build_light_command, nil, true)
assert(ok_nil_id, "build_light_command must not throw when id is nil")
print("[PASS] build_light_command tolerates nil id")

local ok_bad_speed = pcall(protocol.build_fan_speed, 1, "not-a-number")
assert(ok_bad_speed, "build_fan_speed must not throw when speed is not a number")
print("[PASS] build_fan_speed tolerates non-numeric speed")

local ok_nil_speed = pcall(protocol.build_fan_speed, 1, nil)
assert(ok_nil_speed, "build_fan_speed must not throw when speed is nil")
print("[PASS] build_fan_speed tolerates nil speed")

local ok_huge_id = pcall(protocol.build_light_command, 99999, true)
assert(ok_huge_id, "build_light_command must not throw when id is out of byte range")
print("[PASS] build_light_command tolerates out-of-range id")

print("=== All Commax Protocol Tests Passed Successfully! ===")
