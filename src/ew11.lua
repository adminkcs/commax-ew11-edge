local socket = require("cosock.socket")
local log = require("log")
local protocol = require("commax_protocol")

local EW11 = {}
EW11.__index = EW11

-- TX retry/queue defaults, taken from the reference bridge example
-- (commax.homenet_bridge.yaml: tx_retry_cnt=5, tx_timeout=200ms, tx_delay=10ms)
-- and from the actual consumer of those values, command.manager.ts:
--   total attempts = tx_retry_cnt + 1 (first send + retries)
--   tx_timeout = how long to wait for a matching ACK packet before retrying
--   tx_delay   = pause between a timed-out attempt and the next retry
-- On exhausting all attempts, command.manager.ts logs a warning and gives up
-- silently (it does not throw) - this driver mirrors that behavior.
local DEFAULT_TX_RETRY_CNT = 5
local DEFAULT_TX_TIMEOUT = 0.2
local DEFAULT_TX_DELAY = 0.01

-- Defensive bounds (not from the reference source - added because a
-- long-running driver must survive garbage data / command floods without
-- unbounded memory growth):
local MAX_RX_BUFFER = 512    -- bytes; garbage stream with no valid frame ever
local MAX_TX_QUEUE = 20      -- pending commands; drop oldest beyond this
local MIN_RECONNECT_DELAY = 5
local MAX_RECONNECT_DELAY = 60

function EW11.new(driver, ip, port, on_packet_cb)
  local self = setmetatable({}, EW11)
  self.driver = driver
  self.ip = ip
  self.port = tonumber(port) or 8899
  self.on_packet_cb = on_packet_cb
  self.sock = nil
  self.running = false
  self.buffer = ""

  -- Command TX queue: RS485 is a shared half-duplex bus, so commands are
  -- serialized (one at a time, ACK-confirmed) rather than fired concurrently.
  self.tx_queue = {}
  self.pending = nil -- in-flight job awaiting ACK: {packet, ack_prefix, attempts_left, sent_at}
  self.tx_retry_cnt = DEFAULT_TX_RETRY_CNT
  self.tx_timeout = DEFAULT_TX_TIMEOUT
  self.tx_delay = DEFAULT_TX_DELAY

  -- rx_timeout: stale partial-buffer discard threshold (packet-parser.ts),
  -- default 10ms per the reference bridge config.
  self.rx_timeout = 0.01
  self.last_rx_time = nil

  -- Reconnect backoff state (not from reference source): avoids hammering
  -- the network / log with a reconnect attempt every few seconds forever
  -- when EW11 is down for an extended period.
  self.reconnect_delay = MIN_RECONNECT_DELAY
  return self
end

function EW11:start()
  if self.running then return end
  self.running = true

  -- Spawn background reader coroutine via cosock
  self.driver:call_with_delay(0.1, function()
    self:_connection_loop()
  end)
  -- Spawn the command TX queue processor
  self.driver:call_with_delay(0.1, function()
    self:_tx_queue_loop()
  end)
end

function EW11:stop()
  self.running = false
  if self.sock then
    self.sock:close()
    self.sock = nil
  end
end

function EW11:update_config(ip, port)
  local changed = (self.ip ~= ip or self.port ~= tonumber(port))
  self.ip = ip
  self.port = tonumber(port) or 8899
  if changed and self.sock then
    log.info(string.format("[EW11] Configuration updated to %s:%d. Reconnecting...", self.ip, self.port))
    self.sock:close()
    self.sock = nil
  end
end

--- Enqueue a command packet for transmission.
--- @param raw_packet string  the 8-byte packet to send
--- @param ack_prefix table|nil  byte array; if given, the queue waits for a
---   validly-parsed RX packet whose raw bytes start with this prefix before
---   considering the command acknowledged, retrying up to tx_retry_cnt times
---   on timeout. If nil, the command is fire-and-forget (queue moves on
---   immediately after the write).
function EW11:send(raw_packet, ack_prefix)
  if type(raw_packet) ~= "string" or #raw_packet ~= protocol.PACKET_LEN then
    log.error("[EW11] send() rejected: not a valid 8-byte packet")
    return
  end
  -- Command flooding (e.g. an automation hammering ON/OFF) must not grow
  -- the queue without bound. Drop the oldest queued command rather than the
  -- newest - the newest reflects the user's latest intent.
  if #self.tx_queue >= MAX_TX_QUEUE then
    log.warn(string.format("[EW11] TX queue full (%d), dropping oldest queued command", MAX_TX_QUEUE))
    table.remove(self.tx_queue, 1)
  end
  table.insert(self.tx_queue, {
    packet = raw_packet,
    ack_prefix = ack_prefix,
    attempts_left = self.tx_retry_cnt,
  })
end

--- Write a packet to the socket immediately (used internally by the queue).
--- Captures self.sock into a local before use: _connection_loop runs as a
--- separate coroutine and can nil out self.sock (on disconnect) at any
--- yield point, so re-reading self.sock mid-function could hand us nil
--- between the guard check and the send call.
function EW11:_write(raw_packet)
  local sock = self.sock
  if not sock then
    log.warn("[EW11] Send failed: socket not connected")
    return false
  end
  local ok, sent, err = pcall(function() return sock:send(raw_packet) end)
  if not ok then
    log.error(string.format("[EW11] Send raised an error: %s", tostring(sent)))
    return false
  end
  if not sent then
    log.error(string.format("[EW11] Send error: %s", tostring(err)))
    return false
  end
  log.debug(string.format("[EW11] TX -> %s", protocol.to_hex(raw_packet)))
  return true
end

--- One iteration of the TX queue: separated out so _tx_queue_loop can wrap
--- it in pcall without an error inside ever killing the whole coroutine
--- (which would silently stop ALL future commands from being sent).
function EW11:_tx_queue_tick()
  if self.pending then
    local elapsed = socket.gettime() - self.pending.sent_at
    if elapsed >= self.tx_timeout then
      if not self.sock then
        -- Disconnected: don't burn retry attempts while there is no
        -- connection to send on. Just keep waiting for reconnection.
        self.pending.sent_at = socket.gettime()
        return
      end
      self.pending.attempts_left = self.pending.attempts_left - 1
      if self.pending.attempts_left < 0 then
        log.warn(string.format(
          "[EW11] Command failed: no ACK after %d attempt(s) -> %s",
          self.tx_retry_cnt + 1, protocol.to_hex(self.pending.packet)))
        self.pending = nil
      else
        socket.sleep(self.tx_delay)
        self:_write(self.pending.packet)
        self.pending.sent_at = socket.gettime()
      end
    end
  elseif #self.tx_queue > 0 then
    local job = table.remove(self.tx_queue, 1)
    if self:_write(job.packet) then
      if job.ack_prefix then
        job.sent_at = socket.gettime()
        self.pending = job
      end
      -- no ack_prefix: fire-and-forget, queue advances immediately
    end
  end
end

--- Serialize and retry command packets, mirroring the reference bridge's
--- command.manager.ts: one in-flight command at a time, ACK-confirmed,
--- retried on timeout, silently given up on exhaustion.
function EW11:_tx_queue_loop()
  while self.running do
    local ok, err = pcall(function() self:_tx_queue_tick() end)
    if not ok then
      log.error(string.format("[EW11] TX queue tick error (recovered): %s", tostring(err)))
      self.pending = nil
    end
    socket.sleep(0.01)
  end
end

--- Check whether a validly-parsed RX packet satisfies the currently pending
--- command's ACK, and if so clear it so the queue can advance.
function EW11:_check_ack(raw_bytes)
  if not self.pending or not self.pending.ack_prefix then return end
  local prefix = self.pending.ack_prefix
  for i = 1, #prefix do
    if string.byte(raw_bytes, i) ~= prefix[i] then return end
  end
  log.debug(string.format("[EW11] ACK matched for %s", protocol.to_hex(self.pending.packet)))
  self.pending = nil
end

--- One iteration of the connect/read state machine, factored out so
--- _connection_loop can pcall it - an unexpected error here (e.g. a bug in
--- a device-specific packet handler invoked via on_packet_cb) must not
--- kill the read loop, since that would silently stop state updates for
--- EVERY device, not just the one that triggered the error.
function EW11:_connection_tick()
  if not self.sock then
    log.info(string.format("[EW11] Connecting to %s:%d ...", self.ip, self.port))
    local tcp = socket.tcp()
    tcp:settimeout(5)
    local res, err = tcp:connect(self.ip, self.port)
    if res then
      log.info(string.format("[EW11] Connected successfully to %s:%d", self.ip, self.port))
      tcp:settimeout(0.1)
      self.sock = tcp
      self.buffer = ""
      self.reconnect_delay = MIN_RECONNECT_DELAY -- reset backoff on success
    else
      tcp:close()
      log.warn(string.format("[EW11] Connection failed (%s), retrying in %ds...", tostring(err), self.reconnect_delay))
      socket.sleep(self.reconnect_delay)
      -- Exponential backoff, capped, so a prolonged outage doesn't flood
      -- the log with a warning every few seconds indefinitely.
      self.reconnect_delay = math.min(self.reconnect_delay * 2, MAX_RECONNECT_DELAY)
    end
  else
    -- Reading loop: read up to 256 bytes at a time (non-blocking under
    -- cosock's coroutine scheduler). "*a" would block until the peer
    -- closes the connection, which never happens on a live EW11 stream.
    self.sock:settimeout(0.1)
    local chunk, err, partial = self.sock:receive(256)
    chunk = chunk or partial
    if chunk and #chunk > 0 then
      -- rx_timeout: if it has been too long since the last chunk, any
      -- leftover partial bytes in the buffer are stale fragments (e.g. a
      -- torn packet from a dropped connection) - discard them instead of
      -- letting them corrupt framing of the new data. Mirrors
      -- packet-parser.ts's rx_timeout handling (default 10ms in the
      -- reference bridge config).
      local now = socket.gettime()
      if #self.buffer > 0 and self.last_rx_time and (now - self.last_rx_time) > self.rx_timeout then
        log.debug("[EW11] rx_timeout exceeded, discarding stale partial buffer")
        self.buffer = ""
      end
      self.last_rx_time = now
      self.buffer = self.buffer .. chunk

      -- Buffer overflow guard: if noise/garbage keeps arriving with no
      -- valid 8-byte frame ever found, _process_buffer's byte-shift sync
      -- would otherwise let the buffer grow without bound.
      if #self.buffer > MAX_RX_BUFFER then
        log.warn(string.format("[EW11] RX buffer exceeded %d bytes with no valid frame, discarding", MAX_RX_BUFFER))
        self.buffer = ""
      end

      self:_process_buffer()
    elseif err == "closed" then
      log.warn("[EW11] Connection closed by peer. Reconnecting...")
      self.sock:close()
      self.sock = nil
    else
      -- Timeout (no data yet) - yield briefly and retry
      socket.sleep(0.02)
    end
  end
end

function EW11:_connection_loop()
  while self.running do
    local ok, err = pcall(function() self:_connection_tick() end)
    if not ok then
      log.error(string.format("[EW11] Connection loop error (recovered): %s", tostring(err)))
      -- Unknown failure state - drop the socket and let the top of the
      -- loop re-establish a clean connection rather than risk spinning on
      -- a socket left in a bad state.
      if self.sock then
        pcall(function() self.sock:close() end)
        self.sock = nil
      end
      socket.sleep(1)
    end
  end
end

--- Frame synchronization for fixed 8-byte packets
function EW11:_process_buffer()
  while #self.buffer >= protocol.PACKET_LEN do
    -- Candidate 8-byte slice
    local candidate = self.buffer:sub(1, protocol.PACKET_LEN)
    local parse_ok, parsed, perr = pcall(protocol.parse_packet, candidate)

    if parse_ok and parsed then
      -- Valid packet recognized and checksum verified
      log.debug(string.format("[EW11] RX Valid <- %s", protocol.to_hex(candidate)))
      self:_check_ack(candidate)
      if self.on_packet_cb then
        -- Isolate the device-state callback: if it errors (e.g. a bad
        -- capability value for one specific device), the REMAINING
        -- packets already coalesced into this same TCP read must still
        -- be processed - one bad device update must not stall the others.
        local cb_ok, cb_err = pcall(self.on_packet_cb, parsed)
        if not cb_ok then
          log.error(string.format("[EW11] on_packet_cb error (recovered): %s", tostring(cb_err)))
        end
      end
      self.buffer = self.buffer:sub(protocol.PACKET_LEN + 1)
    elseif not parse_ok then
      -- parse_packet itself raised unexpectedly - treat like any other
      -- invalid candidate rather than letting it propagate and kill the
      -- read loop.
      log.error(string.format("[EW11] parse_packet error (recovered): %s", tostring(parsed)))
      self.buffer = self.buffer:sub(2)
    else
      -- Shift by 1 byte to regain boundary sync
      self.buffer = self.buffer:sub(2)
    end
  end
end

return EW11
