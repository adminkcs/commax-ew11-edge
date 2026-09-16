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

--- Decode two consecutive BCD bytes as a single 0..9999 number
--- (each byte contributes two decimal digits, high byte first).
--- e.g. decode_word(0x13, 0x13) -> 1313
function bcd.decode_word(hi, lo)
  return bcd.decode(hi) * 100 + bcd.decode(lo)
end

return bcd
