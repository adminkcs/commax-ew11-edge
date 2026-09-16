-- =========================================================================
-- EW11 Framing/Buffer Offline Test Suite
--
-- Exercises the TCP-framing edge cases from the failure-mode review that
-- don't need a live socket at all: fragmentation, coalescing, garbage
-- mixed with valid packets, and the RX buffer overflow guard. Uses mock
-- `log` and `cosock.socket` modules (tests/mocks/) so ew11.lua can be
-- required without the real SmartThings Lua runtime.
-- =========================================================================
package.path = "mocks/?.lua;mocks/?/init.lua;" .. package.path

local EW11 = require("ew11")
local socket = require("cosock.socket")

local function hex_to_bin(hex_str)
  local clean = hex_str:gsub("%s+", "")
  local t = {}
  for i = 1, #clean, 2 do
    table.insert(t, string.char(tonumber(clean:sub(i, i + 1), 16)))
  end
  return table.concat(t)
end

print("=== Starting EW11 Buffer/Framing Tests ===")

-- 1. Fragmentation: a single valid packet arrives split across two chunks.
-- The real EW11 stream has no guarantee that one RS485 frame maps to one
-- TCP read.
do
  local received = {}
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function(parsed)
    table.insert(received, parsed)
  end)
  local full = hex_to_bin("B0 01 01 00 00 00 00 B2") -- light 1 ON, valid checksum
  ew11.buffer = full:sub(1, 3) -- "B0 01 01" arrives first
  ew11:_process_buffer()
  assert(#received == 0, "Fragmented packet must not be reported before it is complete")
  ew11.buffer = ew11.buffer .. full:sub(4) -- rest of the packet arrives
  ew11:_process_buffer()
  assert(#received == 1 and received[1].device_type == "light" and received[1].is_on == true,
    "Fragmented packet must be correctly reassembled once complete")
  print("[PASS] Fragmentation: packet split across two reads is reassembled correctly")
end

-- 2. Coalescing: two valid packets arrive concatenated in a single chunk
-- (common when EW11/TCP batches RS485 bytes before flushing).
do
  local received = {}
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function(parsed)
    table.insert(received, parsed)
  end)
  local light_on = hex_to_bin("B0 01 01 00 00 00 00 B2")
  local gas_closed = hex_to_bin("90 40 40 00 00 00 00 10")
  ew11.buffer = light_on .. gas_closed
  ew11:_process_buffer()
  assert(#received == 2, "Both coalesced packets must be processed from a single chunk")
  assert(received[1].device_type == "light" and received[2].device_type == "gas",
    "Coalesced packets must be processed in arrival order")
  print("[PASS] Coalescing: two packets in one chunk are both processed, in order")
end

-- 3. Garbage + valid packet: noise on the bus must not prevent the
-- following valid packet from being recognized (byte-shift resync).
do
  local received = {}
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function(parsed)
    table.insert(received, parsed)
  end)
  local garbage = string.char(0xFF, 0xFE, 0x00, 0x12, 0x34)
  local valid = hex_to_bin("B0 01 01 00 00 00 00 B2")
  ew11.buffer = garbage .. valid
  ew11:_process_buffer()
  assert(#received == 1 and received[1].device_type == "light",
    "Valid packet following garbage bytes must still be recognized")
  print("[PASS] Garbage+valid: resync via byte-shift recovers the following valid packet")
end

-- 4. on_packet_cb throwing must not stop the REMAINING coalesced packets
-- in the same chunk from being processed (device isolation).
do
  local received = {}
  local call_count = 0
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function(parsed)
    call_count = call_count + 1
    if call_count == 1 then
      error("simulated bug in one device's state handler")
    end
    table.insert(received, parsed)
  end)
  local light_on = hex_to_bin("B0 01 01 00 00 00 00 B2")
  local gas_closed = hex_to_bin("90 40 40 00 00 00 00 10")
  ew11.buffer = light_on .. gas_closed
  local ok = pcall(function() ew11:_process_buffer() end)
  assert(ok, "_process_buffer itself must not raise even if on_packet_cb does")
  assert(call_count == 2, "on_packet_cb must still be invoked for the packet after the failing one")
  assert(#received == 1 and received[1].device_type == "gas",
    "The packet after a callback failure must still reach the caller")
  print("[PASS] Device isolation: a throwing callback for one packet doesn't block the next packet")
end

-- 5. Buffer overflow: continuous garbage with no valid frame must not grow
-- the buffer without bound (would otherwise leak memory over long uptime).
do
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  -- Simulate what _connection_tick does: append and enforce the cap.
  -- (We exercise the buffer field directly since _connection_tick needs a
  -- live socket; the cap check itself is pure buffer-length logic.)
  ew11.buffer = string.rep("\xFF", 1000) -- far beyond any 8-byte frame boundary
  ew11:_process_buffer() -- shifts byte-by-byte; buffer never finds a valid frame
  assert(#ew11.buffer < 8, "_process_buffer should have consumed all bytes down to <8 (no valid frame ever found)")
  print("[PASS] Buffer with no valid frame is fully drained by byte-shift resync, not stuck growing")
end

-- 6. Bus idle guard: TX must be withheld for a short window after the last
-- RX, to avoid colliding with in-flight RS485 traffic (cross-checked
-- against kimtc99/HAaddons's 100ms post-RX send guard).
do
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  assert(ew11:_bus_busy() == false, "Bus must read as idle when nothing has been received yet")

  ew11.last_rx_time = socket.gettime()
  assert(ew11:_bus_busy() == true, "Bus must read as busy immediately after a receive")

  ew11.last_rx_time = socket.gettime() - 1.0 -- 1s ago, well past the 100ms guard
  assert(ew11:_bus_busy() == false, "Bus must read as idle once the guard window has elapsed")
  print("[PASS] Bus idle guard: TX is withheld right after RX, allowed again once idle")
end

print("=== All EW11 Buffer/Framing Tests Passed Successfully! ===")
