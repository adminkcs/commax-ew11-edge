-- Minimal stand-in for cosock.socket, so ew11.lua can be required offline
-- for testing the parts of it that don't actually need a live network
-- connection (buffer/framing logic in _process_buffer). tcp() is never
-- expected to be called by these tests - only gettime/sleep are used by
-- the code paths under test.
local socket = {}

function socket.gettime()
  return os.clock()
end

function socket.sleep(seconds) end

function socket.tcp()
  error("mock socket.tcp() was called - this test should not open real connections")
end

return socket
