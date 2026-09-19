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
local ack = protocol.ack_elevator_call_down()

print("--- Step 1: Enqueue elevator call (burst_count=2, retry_count=0) ---")
ew:send(pkt, ack, {
  tag = "elevator",
  burst_count = 2,
  burst_delay = 0.015,
  retry_count = 0,
  ack_timeout = 1.0,
  rx_timeout = 0.05,
})

print("--- Step 2: Tick queue to transmit initial burst ---")
ew:_tx_queue_tick()

print(string.format("Packets sent on initial burst: %d", #sent_packets))
for i, p in ipairs(sent_packets) do
  print(string.format("  [%d] %s", i, p))
end

assert(#sent_packets == 2, "FAIL: Expected exactly 2 packets in burst!")
assert(ew.pending ~= nil, "FAIL: Pending job must exist while waiting for ACK")
assert(ew.pending.attempts_left == 0, "FAIL: attempts_left must be 0 (no retries)")

print("--- Step 3: Simulate 1.1s timeout elapsed without ACK ---")
ew.pending.sent_at = socket.gettime() - 1.1

ew:_tx_queue_tick()

print(string.format("Total packets sent after timeout: %d", #sent_packets))
assert(#sent_packets == 2, "FAIL: Retries were sent! Expected still exactly 2 packets!")
assert(ew.pending == nil, "FAIL: Pending job should be cleared after attempts exhausted without retrying!")

print("=== VERIFICATION PASSED: Exactly 2 packets sent, 0 retries on timeout! ===")
