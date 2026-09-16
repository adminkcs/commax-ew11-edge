<#
.SYNOPSIS
  Connects directly to an EW11 (RS485-to-TCP bridge) and dumps every byte
  it sends as hex, framed into 8-byte candidates with checksum validation -
  the same framing rule the Edge Driver uses (src/commax_protocol.lua).

  This is a standalone diagnostic tool. It does NOT install or run the
  SmartThings Edge Driver - it just lets you watch the raw RS485 traffic
  coming through EW11 while you operate the wallpad (physically or via its
  own buttons), so you can confirm which packet bytes correspond to which
  action BEFORE trusting the driver's packet tables.

.USAGE
  powershell -ExecutionPolicy Bypass -File tools\capture_ew11.ps1 -Ip 192.168.0.83 -Port 8899

.NOTES
  - Read-only: this script only listens, it never sends anything to the bus.
  - Press Ctrl+C to stop.
  - Safe for the gas valve: this only observes what's already on the bus;
    it never issues a command.
#>
param(
  [Parameter(Mandatory = $true)][string]$Ip,
  [int]$Port = 8899
)

function Test-Checksum {
  param([byte[]]$Bytes)
  $sum = 0
  for ($i = 0; $i -lt 7; $i++) { $sum = ($sum + $Bytes[$i]) -band 0xFF }
  return $sum -eq $Bytes[7]
}

function Convert-BytesToHex {
  # Named to avoid colliding with the built-in Format-Hex cmdlet (which
  # takes a -Path and dumps a FILE's contents - a name collision here
  # caused PowerShell to bind our byte array into that cmdlet's -Path
  # parameter instead of our own function, producing bogus
  # "Resolve-Path ... 176 0 3 0 0 0 0 179" errors).
  param([byte[]]$Bytes)
  return ($Bytes | ForEach-Object { $_.ToString("X2") }) -join " "
}

Write-Host "Connecting to $Ip`:$Port ..." -ForegroundColor Cyan
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($Ip, $Port)
Write-Host "Connected. Listening for RS485 traffic (Ctrl+C to stop)..." -ForegroundColor Green
Write-Host "Operate lights/heater/fan/gas now and watch the [VALID] lines below.`n"

$stream = $client.GetStream()
$stream.ReadTimeout = 500
$buffer = New-Object System.Collections.Generic.List[byte]
$readBuf = New-Object byte[] 256

try {
  while ($true) {
    try {
      $n = $stream.Read($readBuf, 0, $readBuf.Length)
      if ($n -gt 0) {
        for ($i = 0; $i -lt $n; $i++) { $buffer.Add($readBuf[$i]) }
      } elseif ($n -eq 0) {
        Write-Host "Connection closed by EW11." -ForegroundColor Yellow
        break
      }
    } catch [System.IO.IOException] {
      # read timeout - normal, just loop and try again
    }

    while ($buffer.Count -ge 8) {
      $candidate = $buffer.GetRange(0, 8).ToArray()
      $ts = (Get-Date).ToString("HH:mm:ss.fff")
      if (Test-Checksum $candidate) {
        Write-Host "[$ts] [VALID]   $(Convert-BytesToHex $candidate)" -ForegroundColor Green
        $buffer.RemoveRange(0, 8)
      } else {
        Write-Host "[$ts] [shift]   $(Convert-BytesToHex $candidate)" -ForegroundColor DarkGray
        $buffer.RemoveAt(0)
      }
    }
  }
} finally {
  $stream.Close()
  $client.Close()
  Write-Host "`nDisconnected."
}
