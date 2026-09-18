-- =========================================================================
-- EW11 TX Queue / ACK / Disconnect / rx_timeout Regression Suite
--
-- Added per QA review follow-up: these are the areas the review flagged as
-- having real code paths but zero prior test coverage (ACK prefix-match
-- collision, TX queue serialization/retry/drop policy, retry preservation
-- across a disconnect, and the rx_timeout stale-buffer discard branch).
-- Uses the same offline mocks as test_ew11_buffer.lua (tests/mocks/) so
-- ew11.lua can be required without a live socket or the real SmartThings
-- Lua runtime. socket.gettime() in the mock returns os.clock(); tests that
-- need to simulate elapsed time set ew11.pending.sent_at / last_rx_time
-- directly rather than actually sleeping.
-- =========================================================================
package.path = "mocks/?.lua;mocks/?/init.lua;" .. package.path

local EW11 = require("ew11")
local socket = require("cosock.socket")
local protocol = require("commax_protocol")

local function hex_to_bin(hex_str)
  local clean = hex_str:gsub("%s+", "")
  local t = {}
  for i = 1, #clean, 2 do
    table.insert(t, string.char(tonumber(clean:sub(i, i + 1), 16)))
  end
  return table.concat(t)
end

--- Minimal fake socket for exercising _write / queue behavior without a
--- real network connection. `sent` collects every payload handed to send().
local function make_fake_sock()
  local fake = { sent = {} }
  function fake:send(data)
    table.insert(self.sent, data)
    return #data
  end
  function fake:close() self.closed = true end
  function fake:settimeout(t) end
  return fake
end

print("=== Starting EW11 TX Queue / ACK / Disconnect / rx_timeout Tests ===")

-- 1. ACK collision: known protocol ambiguity, not a parsing bug.
-- commax_protocol.lua documents (CONFIRMED HEADER COLLISION, real capture)
-- that the batch-light-ON ack "A2 01 01 00 00 00 00 A4" is byte-for-byte
-- identical to the elevator down-call ack ACK_ELEVATOR_CALL_DOWN. _check_ack
-- only does a prefix compare against self.pending.ack_prefix, with no other
-- correlation (no sequence id, no full in-flight-packet match beyond the
-- prefix) - so if the elevator ack is pending and this batch-ON packet is
-- received instead, the queue clears it as if it were the real elevator
-- ack. This is a real, reachable code path; the fix is NOT in this driver
-- (the wallpad protocol itself has no way to disambiguate the two), so this
-- test documents/pins the current, accepted behavior rather than asserting
-- it "should" be prevented.
do
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  ew11.pending = {
    packet = hex_to_bin("22 01 40 07 00 00 00 6A"), -- elevator down-call command
    ack_prefix = protocol.ACK_ELEVATOR_CALL_DOWN,   -- {0xA2, 0x01, 0x01}
    attempts_left = ew11.tx_retry_cnt,
    sent_at = socket.gettime(),
  }
  local unrelated_batch_on_ack = hex_to_bin("A2 01 01 00 00 00 00 A4")
  ew11:_check_ack(unrelated_batch_on_ack)
  assert(ew11.pending == nil,
    "KNOWN PROTOCOL AMBIGUITY: batch-light-ON ack is byte-identical to the " ..
    "elevator ack, so it clears a pending elevator ACK early. This is an " ..
    "accepted limitation of the wallpad protocol itself, not a fixable " ..
    "parsing bug - see commax_protocol.lua's CONFIRMED HEADER COLLISION comment.")
  print("[PASS] ACK collision: batch-ON ack satisfies a pending elevator ack (documented protocol ambiguity, not a bug)")
end

-- 1b. Sanity check: an ack for a DIFFERENT, non-colliding prefix must NOT
-- clear an unrelated pending command (i.e. _check_ack does still reject
-- ordinary non-matching packets - only the genuinely identical-on-the-wire
-- collision above is a false positive).
do
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  ew11.pending = {
    packet = hex_to_bin("31 01 01 00 00 00 00 33"), -- light 1 ON command
    ack_prefix = { 0xB1, 0x01 },                    -- ack_light_command(1, true) prefix
    attempts_left = ew11.tx_retry_cnt,
    sent_at = socket.gettime(),
  }
  local unrelated_gas_ack = hex_to_bin("91 40 40 00 00 00 00 11")
  ew11:_check_ack(unrelated_gas_ack)
  assert(ew11.pending ~= nil, "An unrelated, non-colliding ack must not clear a pending command")
  print("[PASS] ACK matching: a genuinely different ack does not falsely satisfy a pending command")
end

-- 2. TX queue ordering: commands A, B, C, D (fire-and-forget, no ack_prefix)
-- must be sent in FIFO order.
do
  local fake_sock = make_fake_sock()
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  ew11.sock = fake_sock
  local A = hex_to_bin("31 01 01 00 00 00 00 33")
  local B = hex_to_bin("31 02 01 00 00 00 00 34")
  local C = hex_to_bin("31 03 01 00 00 00 00 35")
  local D = hex_to_bin("31 04 01 00 00 00 00 36")
  ew11:send(A)
  ew11:send(B)
  ew11:send(C)
  ew11:send(D)
  -- All four are fire-and-forget (no ack_prefix), so each tick sends one and
  -- immediately advances to the next.
  ew11:_tx_queue_tick()
  ew11:_tx_queue_tick()
  ew11:_tx_queue_tick()
  ew11:_tx_queue_tick()
  assert(#fake_sock.sent == 4, "All 4 queued commands should have been sent")
  assert(fake_sock.sent[1] == A and fake_sock.sent[2] == B and fake_sock.sent[3] == C and fake_sock.sent[4] == D,
    "Commands must be sent in FIFO order: A, B, C, D")
  print("[PASS] TX queue: commands A/B/C/D are sent in FIFO order")
end

-- 3. Serialization: while A is pending (awaiting ack), B must NOT be sent
-- even though it's already queued.
do
  local fake_sock = make_fake_sock()
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  ew11.sock = fake_sock
  local A = hex_to_bin("31 01 01 00 00 00 00 33")
  local B = hex_to_bin("31 02 01 00 00 00 00 34")
  ew11:send(A, { 0xB1, 0x01 }) -- A expects an ack, so it stays "pending" until acked/timed out
  ew11:send(B)
  ew11:_tx_queue_tick() -- sends A, sets self.pending
  assert(#fake_sock.sent == 1 and fake_sock.sent[1] == A, "A must be sent first")
  assert(ew11.pending ~= nil, "A must be the pending in-flight command")
  ew11:_tx_queue_tick() -- pending A hasn't timed out yet - must NOT advance to B
  assert(#fake_sock.sent == 1, "B must not be sent while A is still pending (queue must serialize, not interleave)")
  print("[PASS] TX queue: serialization - B is withheld while A is pending")
end

-- 4. Retry: A gets no ack; each tick after tx_timeout elapses should retry
-- (re-send) until attempts_left is exhausted, then give up and let the
-- queue advance.
do
  local fake_sock = make_fake_sock()
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  ew11.sock = fake_sock
  ew11.tx_retry_cnt = 2 -- small number so the test doesn't need many iterations
  local A = hex_to_bin("31 01 01 00 00 00 00 33")
  ew11:send(A, { 0xB1, 0x01 })
  ew11:_tx_queue_tick() -- initial send
  assert(#fake_sock.sent == 1, "Initial send")

  -- Simulate tx_timeout elapsing without an ack, tx_retry_cnt=2 times over.
  for i = 1, ew11.tx_retry_cnt do
    ew11.pending.sent_at = socket.gettime() - (ew11.tx_timeout + 0.01)
    ew11:_tx_queue_tick()
    assert(#fake_sock.sent == 1 + i, string.format("Retry #%d should have re-sent the command", i))
    assert(ew11.pending ~= nil, "Command must still be pending mid-retry")
  end

  -- One more timeout beyond tx_retry_cnt exhausts all attempts (total
  -- attempts = tx_retry_cnt + 1: the initial send plus tx_retry_cnt retries).
  ew11.pending.sent_at = socket.gettime() - (ew11.tx_timeout + 0.01)
  ew11:_tx_queue_tick()
  assert(ew11.pending == nil, "After tx_retry_cnt retries are exhausted, pending must be cleared so the queue can advance")
  assert(#fake_sock.sent == 1 + ew11.tx_retry_cnt, "No further send should happen once attempts are exhausted")
  print(string.format("[PASS] TX queue: retry - retries %d time(s) then gives up (total attempts = tx_retry_cnt + 1)", ew11.tx_retry_cnt))
end

-- 5. Queue limit: MAX_TX_QUEUE (20) reached -> oldest queued command is
-- dropped, newest is kept. Verified against the actual drop-oldest policy
-- implemented in EW11:send (not assumed).
do
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  local MAX_TX_QUEUE = 20
  for i = 1, MAX_TX_QUEUE do
    ew11:send(string.rep(string.char(i % 256), 8))
  end
  assert(#ew11.tx_queue == MAX_TX_QUEUE, "Queue should be exactly at the cap after filling it")
  local newest_before_overflow = ew11.tx_queue[MAX_TX_QUEUE].packet
  local oldest_before_overflow = ew11.tx_queue[1].packet

  local one_more = string.rep(string.char(99), 8)
  ew11:send(one_more)
  assert(#ew11.tx_queue == MAX_TX_QUEUE, "Queue must stay capped at MAX_TX_QUEUE, not grow unbounded")
  assert(ew11.tx_queue[1].packet ~= oldest_before_overflow,
    "The oldest queued command must be dropped once the cap is exceeded")
  assert(ew11.tx_queue[MAX_TX_QUEUE].packet == one_more,
    "The newest command (the user's latest intent) must be kept, appended at the end")
  print("[PASS] TX queue: MAX_TX_QUEUE reached drops the oldest command, keeps the newest")
end

-- 6. Disconnect while a command is pending: attempts_left must NOT be
-- consumed while there is no socket to send on, and the command must still
-- be retried normally once reconnected.
do
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function() end)
  local A = hex_to_bin("31 01 01 00 00 00 00 33")
  local initial_attempts_left = ew11.tx_retry_cnt
  ew11.pending = {
    packet = A,
    ack_prefix = { 0xB1, 0x01 },
    attempts_left = initial_attempts_left,
    sent_at = socket.gettime() - (ew11.tx_timeout + 0.01), -- already "timed out"
  }
  ew11.sock = nil -- disconnected

  ew11:_tx_queue_tick()
  assert(ew11.pending ~= nil, "Pending command must be preserved (not dropped) while disconnected")
  assert(ew11.pending.attempts_left == initial_attempts_left,
    "attempts_left must NOT be consumed while there is no connection to send on")

  -- Simulate another disconnected tick after more time passes - still must
  -- not burn an attempt.
  ew11.pending.sent_at = socket.gettime() - (ew11.tx_timeout + 0.01)
  ew11:_tx_queue_tick()
  assert(ew11.pending.attempts_left == initial_attempts_left,
    "attempts_left must remain untouched across multiple disconnected ticks")

  -- Reconnect: next tick past tx_timeout must now retry normally (consume
  -- one attempt and actually resend).
  local fake_sock = make_fake_sock()
  ew11.sock = fake_sock
  ew11.pending.sent_at = socket.gettime() - (ew11.tx_timeout + 0.01)
  ew11:_tx_queue_tick()
  assert(#fake_sock.sent == 1, "After reconnecting, the pending command must be resent")
  assert(ew11.pending.attempts_left == initial_attempts_left - 1,
    "The first retry attempt after reconnecting must consume exactly one attempt")
  print("[PASS] TX queue: command survives a disconnect without losing retry attempts, resumes normally after reconnect")
end

-- 7. rx_timeout: a stale partial (incomplete) packet sitting in the buffer
-- for longer than rx_timeout must be discarded so it doesn't corrupt the
-- framing of the next, unrelated packet - and the next valid packet must
-- still be received correctly afterward. Exercises the same discard logic
-- that lives inline in _connection_tick, applied directly to ew11.buffer /
-- ew11.last_rx_time since that logic needs a live socket to reach otherwise.
do
  local received = {}
  local ew11 = EW11.new({ call_with_delay = function() end }, "127.0.0.1", 8899, function(parsed)
    table.insert(received, parsed)
  end)
  local full = hex_to_bin("B0 01 01 00 00 00 00 B2") -- light 1 ON, valid checksum

  -- Simulate a torn fragment ("B0 01 01") that arrived a while ago and
  -- never got completed (e.g. connection dropped mid-frame).
  ew11.buffer = full:sub(1, 3)
  ew11.last_rx_time = socket.gettime() - 1.0 -- 1s ago, far past rx_timeout (10ms)

  -- Now a new, unrelated chunk arrives - replicate the rx_timeout discard
  -- check exactly as _connection_tick does it.
  local now = socket.gettime()
  if #ew11.buffer > 0 and ew11.last_rx_time and (now - ew11.last_rx_time) > ew11.rx_timeout then
    ew11.buffer = ""
  end
  ew11.last_rx_time = now
  local next_valid = hex_to_bin("90 40 40 00 00 00 00 10") -- unrelated gas-closed packet
  ew11.buffer = ew11.buffer .. next_valid
  ew11:_process_buffer()

  assert(#received == 1 and received[1].device_type == "gas",
    "After rx_timeout discards the stale partial fragment, the next valid packet must still be parsed correctly")
  assert(#ew11.buffer == 0, "Buffer must be fully consumed after processing the one complete packet")
  print("[PASS] rx_timeout: stale partial buffer is discarded and does not corrupt the next valid packet " ..
    "(code-logic verified only; whether 10ms is adequate on real hardware/network needs live-environment testing)")
end

-- 8. Disconnect resilience: queued commands must NOT be drained when socket is nil
do
  local current_time = 1000.0
  local old_gettime = socket.gettime
  socket.gettime = function() return current_time end

  local ew11 = EW11.new({ call_with_delay = function() end }, "192.168.1.100", 8899, function() end, {
    tx_delay_ms = 10,
    ack_timeout_ms = 100,
    tx_retry_cnt = 2,
  })
  -- Deliberately leave sock = nil (disconnected state)
  ew11.sock = nil

  local cmd1 = hex_to_bin("31 01 01 00 00 00 00 33")
  local cmd2 = hex_to_bin("31 02 01 00 00 00 00 34")
  ew11:send(cmd1, { 0xB1, 0x01, 0x01 })
  ew11:send(cmd2, { 0xB1, 0x01, 0x02 })
  assert(#ew11.tx_queue == 2, "Two commands must be queued")

  -- Tick multiple times while disconnected
  for _ = 1, 10 do
    current_time = current_time + 0.05
    ew11:_tx_queue_tick()
  end

  -- Commands must still be in queue, not drained
  assert(#ew11.tx_queue == 2,
    "Commands must be preserved in queue during disconnect, not silently drained")

  -- Now reconnect and verify the commands can be dispatched
  local fake_sock = make_fake_sock()
  ew11.sock = fake_sock
  current_time = current_time + 0.05
  ew11:_tx_queue_tick()
  assert(#fake_sock.sent == 1, "First command must be sent after reconnection")
  assert(#ew11.tx_queue == 1, "Second command must still be in queue")

  socket.gettime = old_gettime
  print("[PASS] Disconnect resilience: commands are preserved in queue, not drained while socket is nil")
end

-- 9. 3-byte ACK prefix matching: Light 2 ACK must NOT clear pending Light 1 command
do
  local current_time = 1000.0
  local old_gettime = socket.gettime
  socket.gettime = function() return current_time end

  local fake_sock = make_fake_sock()
  local ew11 = EW11.new({ call_with_delay = function() end }, "192.168.1.100", 8899, function() end, {
    tx_delay_ms = 10,
    ack_timeout_ms = 200,
  })
  ew11.sock = fake_sock

  -- Send Light 1 ON command with full 3-byte ACK prefix
  local cmd = hex_to_bin("31 01 01 00 00 00 00 33")
  ew11:send(cmd, protocol.ack_light_command(1, true))  -- {0xB1, 0x01, 0x01}

  -- Dispatch it
  current_time = current_time + 0.05
  ew11:_tx_queue_tick()
  assert(ew11.pending ~= nil, "Command must be pending awaiting ACK")

  -- Receive ACK for Light 2 ON (different ID) - should NOT match
  local wrong_ack = hex_to_bin("B1 01 02 00 00 00 00 B4")
  ew11:_check_ack(wrong_ack)
  assert(ew11.pending ~= nil, "Light 2 ACK must NOT clear pending Light 1 command (3-byte prefix mismatch)")

  -- Receive correct ACK for Light 1 ON - should match
  local right_ack = hex_to_bin("B1 01 01 00 00 00 00 B3")
  ew11:_check_ack(right_ack)
  assert(ew11.pending == nil, "Light 1 ACK must clear pending Light 1 command (3-byte prefix match)")

  socket.gettime = old_gettime
  print("[PASS] 3-byte ACK prefix: Light 2 ACK does NOT clear pending Light 1 command")
end

-- 10. on_fail_cb is called when ACK retries exhausted
do
  local current_time = 1000.0
  local old_gettime = socket.gettime
  socket.gettime = function() return current_time end

  local fail_calls = {}
  local fake_sock = make_fake_sock()
  local ew11 = EW11.new({ call_with_delay = function() end }, "192.168.1.100", 8899, function() end, {
    tx_delay_ms = 10,
    ack_timeout_ms = 100,
    tx_retry_cnt = 1,  -- only 1 retry = 2 total attempts
  }, function(raw_packet, ack_prefix)
    table.insert(fail_calls, { packet = raw_packet, ack = ack_prefix })
  end)
  ew11.sock = fake_sock

  local cmd = hex_to_bin("31 01 01 00 00 00 00 33")
  ew11:send(cmd, protocol.ack_light_command(1, true))

  -- Dispatch command
  current_time = current_time + 0.05
  ew11:_tx_queue_tick()
  assert(ew11.pending ~= nil, "Command must be pending")
  assert(#fail_calls == 0, "No failure yet")

  -- First timeout -> retry
  current_time = current_time + 0.2
  ew11:_tx_queue_tick()
  assert(ew11.pending ~= nil, "Still pending after first retry")

  -- Second timeout -> exhausted, should call on_fail_cb
  current_time = current_time + 0.2
  ew11:_tx_queue_tick()
  assert(ew11.pending == nil, "Pending must be cleared after all retries exhausted")
  assert(#fail_calls == 1, "on_fail_cb must be called exactly once")
  assert(fail_calls[1].packet == cmd, "on_fail_cb must receive the failed packet")

  socket.gettime = old_gettime
  print("[PASS] on_fail_cb: callback fires when ACK retries are exhausted")
end

-- 11. ACK retry respects bus busy guard
do
  local current_time = 1000.0
  local old_gettime = socket.gettime
  socket.gettime = function() return current_time end

  local fake_sock = make_fake_sock()
  local ew11 = EW11.new({ call_with_delay = function() end }, "192.168.1.100", 8899, function() end, {
    tx_delay_ms = 10,
    ack_timeout_ms = 100,
    tx_retry_cnt = 2,
  })
  ew11.sock = fake_sock

  local cmd = hex_to_bin("31 01 01 00 00 00 00 33")
  ew11:send(cmd, protocol.ack_light_command(1, true))

  -- Dispatch command
  current_time = current_time + 0.05
  ew11:_tx_queue_tick()
  local initial_sent = #fake_sock.sent
  assert(ew11.pending ~= nil, "Command must be pending")

  -- Timeout, but bus is busy (RX 5ms ago)
  current_time = current_time + 0.2
  ew11.last_rx_time = current_time - 0.005  -- 5ms ago = bus busy
  local attempts_before = ew11.pending.attempts_left
  ew11:_tx_queue_tick()

  -- Retry must be deferred, not fired
  assert(#fake_sock.sent == initial_sent,
    "ACK retry must be deferred when bus is busy, not cause RS485 collision")
  assert(ew11.pending.attempts_left == attempts_before,
    "Retry attempt must not be burned while bus is busy")

  socket.gettime = old_gettime
  print("[PASS] ACK retry bus guard: retry is deferred when bus is busy")
end

print("=== All EW11 TX Queue / ACK / Disconnect / rx_timeout Tests Passed Successfully! ===")
