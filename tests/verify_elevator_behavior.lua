-- Manual verification script for the elevator call handshake.
--
-- Superseded finding (2026-09-20): this script previously asserted that
-- both packets of a burst_count=2 elevator call are transmitted
-- back-to-back BEFORE any ACK is received, with a single ACK completing
-- the whole burst. That is NOT what real EW11 hardware does: a real
-- capture showed TX #1 -> ACK #1 -> TX #2 -> ACK #2, two full separate
-- request/response exchanges. Firing both packets blindly (only the
-- 15ms burst_delay apart, no ACK gate) is why elevator calls were
-- unreliable while every other ACK-gated command worked. ew11.lua was
-- changed to a real sequential handshake (see EW11:_write_burst_step /
-- EW11:_check_ack); this script now verifies THAT behavior instead.
package.path = "src/?.lua;tests/mocks/?.lua;tests/mocks/?/init.lua;" .. package.path

local EW11 = require("ew11")
local protocol = require("commax_protocol")
local socket = require("cosock.socket")

local ew = EW11.new({ ip = "127.0.0.1", port = 8899 })

local sent_packets = {}
ew.sock = {
  send = function(self, data)
    table.insert(sent_packets, protocol.to_hex(data))
    return #data, nil
  end
}

local pkt = protocol.build_elevator_call_down()
local ack_prefix = protocol.ack_elevator_call_down()
local wallpad_ack = pkt -- placeholder, overwritten below with the real ACK bytes

-- Real-capture-confirmed ACK: "A2 01 01 00 00 00 00 A4"
local function hex_to_bin(hex_str)
  local clean = hex_str:gsub("%s+", "")
  local t = {}
  for i = 1, #clean, 2 do
    table.insert(t, string.char(tonumber(clean:sub(i, i + 1), 16)))
  end
  return table.concat(t)
end
wallpad_ack = hex_to_bin("A2 01 01 00 00 00 00 A4")

print("--- Step 1: Enqueue elevator call (burst_count=2, retry_count=0) ---")
ew:send(pkt, ack_prefix, {
  tag = "elevator",
  burst_count = 2,
  burst_delay = 0.015,
  retry_count = 0,
  ack_timeout = 1.0,
  rx_timeout = 0.05,
})

print("--- Step 2: Tick queue - only TX #1 should go out ---")
ew:_tx_queue_tick()
print(string.format("Packets sent after TX #1: %d", #sent_packets))
for i, p in ipairs(sent_packets) do print(string.format("  [%d] %s", i, p)) end

assert(#sent_packets == 1, "FAIL: TX #2 must NOT be sent before ACK #1 arrives!")
assert(ew.pending ~= nil, "FAIL: Pending job must exist while waiting for ACK #1")
assert(ew.pending.burst_step == 1, "FAIL: burst_step must be 1 while waiting for ACK #1")

print("--- Step 3: ACK #1 arrives -> TX #2 must be sent, call must NOT complete yet ---")
ew:_check_ack(wallpad_ack)
print(string.format("Packets sent after ACK #1: %d", #sent_packets))
for i, p in ipairs(sent_packets) do print(string.format("  [%d] %s", i, p)) end

assert(#sent_packets == 2, "FAIL: ACK #1 must trigger TX #2!")
assert(ew.pending ~= nil, "FAIL: Job must still be pending - waiting for ACK #2 now")
assert(ew.pending.burst_step == 2, "FAIL: burst_step must advance to 2 after ACK #1")

print("--- Step 4: ACK #2 arrives -> call completes, no further transmission ---")
ew:_check_ack(wallpad_ack)
assert(#sent_packets == 2, "FAIL: ACK #2 must not trigger any further transmission")
assert(ew.pending == nil, "FAIL: Pending job must be cleared only after the FINAL ack")

print("--- Step 5: Fresh call, ACK #1 times out -> must fail WITHOUT ever sending TX #2 ---")
sent_packets = {}
ew:send(pkt, ack_prefix, {
  tag = "elevator",
  burst_count = 2,
  burst_delay = 0.015,
  retry_count = 0,
  ack_timeout = 1.0,
  rx_timeout = 0.05,
})
ew:_tx_queue_tick()
assert(#sent_packets == 1, "FAIL: Only TX #1 expected before timeout")
ew.pending.sent_at = socket.gettime() - 1.1
ew:_tx_queue_tick()
assert(#sent_packets == 1, "FAIL: TX #2 must never fire if ACK #1 never arrived")
assert(ew.pending == nil, "FAIL: Pending job should be cleared after step-1 attempts exhausted")

print("=== VERIFICATION PASSED: sequential TX#1->ACK#1->TX#2->ACK#2 handshake, no blind burst ===")
