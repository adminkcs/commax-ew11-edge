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

  Only VALID (checksum-passing) packets are written to the log file, to
  keep it readable - noise/resync bytes still print to the console but are
  not persisted. While it's running, type a short note (e.g. "light8 on")
  and press Enter to drop a timestamped marker line into the log, right
  before you flip a switch - that makes it easy to tell later which
  packets around that timestamp correspond to which action.

.NOTES
  - Read-only: this script only listens, it never sends anything to the bus.
  - Press Ctrl+C to stop.
  - Safe for the gas valve: this only observes what's already on the bus;
    it never issues a command.
#>
param(
  [Parameter(Mandatory = $true)][string]$Ip,
  [int]$Port = 8899,
  [string]$LogFile = ""
)

# $PSScriptRoot can come back empty depending on how the script was
# invoked (e.g. pasted into -Command instead of run via -File), which
# previously caused the default log path to resolve to "\capture_....log"
# - the root of the current drive, which needs admin rights and fails with
# "Access is denied". Fall back to the current working directory instead.
if ([string]::IsNullOrEmpty($LogFile)) {
  $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
  $LogFile = Join-Path $scriptDir "capture_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}

function Test-Checksum {
  param([byte[]]$Bytes)
  $sum = 0
  for ($i = 0; $i -lt 7; $i++) { $sum = ($sum + $Bytes[$i]) -band 0xFF }
  return $sum -eq $Bytes[7]
}

function Write-LogLine {
  # A single failed write (e.g. transient disk/permission issue) must not
  # crash the whole capture - just warn once to the console and keep going.
  param([string]$Line)
  try {
    $Line | Out-File -FilePath $LogFile -Append -Encoding utf8
  } catch {
    Write-Host "(log write failed: $($_.Exception.Message))" -ForegroundColor Red
  }
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

try {
  "# EW11 capture started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') against ${Ip}:${Port}" | Out-File -FilePath $LogFile -Encoding utf8
} catch {
  Write-Host "Could not create log file at '$LogFile': $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Falling back to your Documents folder." -ForegroundColor Yellow
  $LogFile = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "capture_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
  "# EW11 capture started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') against ${Ip}:${Port}" | Out-File -FilePath $LogFile -Encoding utf8
}

Write-Host "Connecting to $Ip`:$Port ..." -ForegroundColor Cyan
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($Ip, $Port)
Write-Host "Connected. Logging valid packets to: $LogFile" -ForegroundColor Green
Write-Host "Type a short note + Enter to drop a marker (e.g. 'light8 on'), then flip the switch." -ForegroundColor Yellow
Write-Host "Ctrl+C to stop.`n"

$stream = $client.GetStream()
$stream.ReadTimeout = 200
$buffer = New-Object System.Collections.Generic.List[byte]
$readBuf = New-Object byte[] 256
$inputLine = New-Object System.Text.StringBuilder
# [Console]::KeyAvailable throws when there is no real console (input
# redirected from a file/pipe, or run non-interactively) - detect that
# once up front instead of crashing the whole capture loop on first use.
$consoleAvailable = $true
try { [void][Console]::KeyAvailable } catch { $consoleAvailable = $false }
if (-not $consoleAvailable) {
  Write-Host "(no interactive console detected - marker notes disabled, capture continues)" -ForegroundColor DarkYellow
}

try {
  while ($true) {
    # Non-blocking check for a typed marker note, so we don't have to stop
    # capturing to record "what I just did".
    while ($consoleAvailable -and [Console]::KeyAvailable) {
      $key = [Console]::ReadKey($true)
      if ($key.Key -eq "Enter") {
        $note = $inputLine.ToString()
        $inputLine.Clear() | Out-Null
        if ($note.Trim().Length -gt 0) {
          $ts = (Get-Date).ToString("HH:mm:ss.fff")
          $line = "[$ts] ==== MARK: $note ===="
          Write-Host $line -ForegroundColor Cyan
          Write-LogLine $line
        }
      } elseif ($key.Key -eq "Backspace") {
        if ($inputLine.Length -gt 0) { $inputLine.Remove($inputLine.Length - 1, 1) | Out-Null }
      } else {
        $inputLine.Append($key.KeyChar) | Out-Null
      }
    }

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
      $hex = Convert-BytesToHex $candidate
      if (Test-Checksum $candidate) {
        $line = "[$ts] [VALID] $hex"
        Write-Host $line -ForegroundColor Green
        Write-LogLine $line
        $buffer.RemoveRange(0, 8)
      } else {
        Write-Host "[$ts] [shift] $hex" -ForegroundColor DarkGray
        $buffer.RemoveAt(0)
      }
    }
  }
} finally {
  $stream.Close()
  $client.Close()
  Write-Host "`nDisconnected. Log saved to: $LogFile"
}
