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

print("=== Starting Light Sync & TX Starvation Guard Tests ===")

-- Test 1: Starvation Guard triggers transmission even under continuous RX traffic
do
  local current_time = 1000.0
  local old_gettime = socket.gettime
  socket.gettime = function() return current_time end

  local fake_sock = make_fake_sock()
  local ew11 = EW11.new({ call_with_delay = function() end }, "192.168.1.100", 8899, function() end, {
    tx_delay_ms = 10,
    ack_timeout_ms = 100,
  })
  ew11.sock = fake_sock

  -- Queue a light command at t = 1000.0
  local cmd = hex_to_bin("31 01 01 00 00 00 00 33")
  ew11:send(cmd)

  -- Simulate continuous RX traffic:
  -- When RX arrived 5ms ago (< BUS_IDLE_GUARD of 20ms) and wait_time is 100ms (< MAX_BUS_WAIT of 300ms)
  current_time = 1000.100
  ew11.last_rx_time = current_time - 0.005 -- 5ms ago
  ew11:_tx_queue_tick()
  assert(#fake_sock.sent == 0, "Packet must be withheld initially while bus is busy (< 20ms) and wait_time < 300ms")

  -- Now advance time to 1000.350 (wait_time = 350ms >= MAX_BUS_WAIT) with bus still busy (RX 5ms ago)
  current_time = 1000.350
  ew11.last_rx_time = current_time - 0.005 -- still continuous RX!
  ew11:_tx_queue_tick()

  socket.gettime = old_gettime

  assert(#fake_sock.sent == 1, "Starvation guard must force TX transmission after 300ms despite continuous RX")
  assert(fake_sock.sent[1] == cmd, "Sent packet must match queued light command")
  print("[PASS] TX Starvation Guard: Command is dispatched despite continuous RX traffic")
end

-- Test 2: Light polling sends queries for configured light count
do
  local query1 = protocol.build_light_query(1)
  local query2 = protocol.build_light_query(2)

  assert(string.format("%02X", query1:byte(1)) == "30", "Light query header must be 0x30")
  assert(query1:byte(2) == 1, "Light 1 query target must be 1")
  assert(query2:byte(2) == 2, "Light 2 query target must be 2")
  print("[PASS] Light Query Packet Generation: Correct format for light polling")
end

print("=== All Light Sync & TX Starvation Guard Tests Passed Successfully! ===")
