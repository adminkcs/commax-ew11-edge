<#
.SYNOPSIS
  One-shot diagnostic: connect to the EW11, send a single raw 8-byte hex
  packet, and print whatever comes back for a few seconds. Used to probe
  an UNCONFIRMED packet (e.g. a candidate query byte from a reference repo)
  against real hardware before trusting it enough to add to
  src/commax_protocol.lua. This is intentionally separate from
  capture_ew11.ps1 (which is read-only) since sending is a deliberate,
  occasional action, not something to run passively.

.USAGE
  powershell -ExecutionPolicy Bypass -File tools\probe_packet.ps1 -Ip 192.168.50.243 -Port 8899 -HexBytes "79 01 02 00 00 00 00 7C"

.NOTES
  - Only send packets you already believe are read-only queries (not
    commands that would change real device state) unless you intend that.
  - Press Ctrl+C to stop early.
#>
param(
  [Parameter(Mandatory = $true)][string]$Ip,
  [int]$Port = 8899,
  [Parameter(Mandatory = $true)][string]$HexBytes,
  [int]$ListenSeconds = 5
)

$bytes = $HexBytes.Split(' ') | Where-Object { $_ -ne '' } | ForEach-Object { [byte]("0x" + $_) }
if ($bytes.Length -ne 8) {
  Write-Error "Expected exactly 8 bytes, got $($bytes.Length): $HexBytes"
  exit 1
}
$cs = 0
for ($i = 0; $i -lt 7; $i++) { $cs = ($cs + $bytes[$i]) -band 0xFF }
if ($cs -ne $bytes[7]) {
  Write-Warning "Checksum mismatch: computed 0x$($cs.ToString('X2')), given 0x$($bytes[7].ToString('X2')) - sending anyway as requested"
}

Write-Host "Connecting to ${Ip}:${Port} ..."
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($Ip, $Port)
$stream = $client.GetStream()
$stream.ReadTimeout = 200

Write-Host "Sending: $HexBytes"
$stream.Write($bytes, 0, $bytes.Length)
$stream.Flush()

$deadline = (Get-Date).AddSeconds($ListenSeconds)
$readBuf = New-Object byte[] 256
while ((Get-Date) -lt $deadline) {
  try {
    $n = $stream.Read($readBuf, 0, $readBuf.Length)
    if ($n -gt 0) {
      $hex = ($readBuf[0..($n-1)] | ForEach-Object { $_.ToString('X2') }) -join ' '
      Write-Host "[$(Get-Date -Format 'HH:mm:ss.fff')] RX: $hex"
    }
  } catch [System.IO.IOException] {
    # read timeout - normal, keep polling until deadline
  }
}

$stream.Close()
$client.Close()
Write-Host "Done."
