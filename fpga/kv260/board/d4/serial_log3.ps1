# serial_log2.ps1 with -Baud (default 115200): e.g. a kernel earlycon running at 230400.
# Log one serial port (115200 8N1, no flow control) to a file until <Out>.stop appears or Minutes pass, like
# serial_log.ps1, but when the port goes away (a USB adapter re-enumerating, e.g. the PMOD's CH340 when the PL is
# reconfigured) it logs the drop and reopens the port every 2 s instead of ending. Read-only: nothing is written.
param([string]$Port, [string]$Out, [int]$Minutes = 240, [int]$Baud = 115200)
$stop = "$Out.stop"
if (Test-Path $stop) { Remove-Item $stop }
$deadline = (Get-Date).AddMinutes($Minutes)
$w = New-Object System.IO.StreamWriter($Out, $true, [System.Text.Encoding]::UTF8)
$w.AutoFlush = $true
$w.WriteLine("`n===== $Port logger (reopening, $Baud baud) started $(Get-Date -Format o) =====")
$sp = $null
try {
  while ((Get-Date) -lt $deadline -and -not (Test-Path $stop)) {
    if (-not $sp -or -not $sp.IsOpen) {
      try {
        $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
        $sp.Handshake = 'None'; $sp.ReadTimeout = 200; $sp.DtrEnable = $false; $sp.RtsEnable = $false
        $sp.Open()
        $w.WriteLine("`n===== $Port opened $(Get-Date -Format o) =====")
      } catch { $sp = $null; Start-Sleep -Seconds 2; continue }
    }
    try {
      $s = $sp.ReadExisting()
      if ($s.Length -gt 0) { $w.Write($s) } else { Start-Sleep -Milliseconds 100 }
    } catch {
      $w.WriteLine("`n===== $Port dropped $(Get-Date -Format o): $($_.Exception.Message) =====")
      try { $sp.Close() } catch {}
      $sp = $null
      Start-Sleep -Seconds 2
    }
  }
} finally {
  if ($sp -and $sp.IsOpen) { $sp.Close() }
  $w.WriteLine("`n===== $Port logger ended $(Get-Date -Format o) =====")
  $w.Close()
}
