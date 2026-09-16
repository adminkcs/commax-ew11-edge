local bcd = {}

--- Encode integer (0..99) to BCD byte
--- e.g. 25 -> 0x25 (37 decimal)
function bcd.encode(val)
  if type(val) ~= "number" then return 0 end
  val = math.floor(val)
  if val < 0 then val = 0 end
  if val > 99 then val = 99 end
  local tens = math.floor(val / 10)
  local ones = val % 10
  return (tens << 4) | ones
end

--- Decode BCD byte to integer
--- e.g. 0x25 -> 25
function bcd.decode(val)
  if type(val) ~= "number" then return 0 end
  local tens = (val >> 4) & 0x0F
  local ones = val & 0x0F
  return (tens * 10) + ones
end

return bcd
