# Log one serial port like serial_log2.ps1 (115200 8N1, read-only, reopening every 2 s when the port goes away, ended
# by <Out>.stop or Minutes), with each line prefixed by the UTC time its first characters arrived, [HH:mm:ss.fff], to
# within the 50 ms poll. For boot timelines: the reset, the firmware's banners, the kernel's start and the login.
param([string]$Port, [string]$Out, [int]$Minutes = 240)
$stop = "$Out.stop"
if (Test-Path $stop) { Remove-Item $stop }
$deadline = (Get-Date).AddMinutes($Minutes)
$w = New-Object System.IO.StreamWriter($Out, $true, [System.Text.Encoding]::UTF8)
$w.AutoFlush = $true
$w.WriteLine("`n===== $Port logger (reopening, UTC line stamps) started $(Get-Date -Format o) =====")
$sp = $null; $bol = $true
try {
  while ((Get-Date) -lt $deadline -and -not (Test-Path $stop)) {
    if (-not $sp -or -not $sp.IsOpen) {
      try {
        $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
        $sp.Handshake = 'None'; $sp.ReadTimeout = 200; $sp.DtrEnable = $false; $sp.RtsEnable = $false
        $sp.Open()
        $w.WriteLine("`n===== $Port opened $(Get-Date -Format o) ====="); $bol = $true
      } catch { $sp = $null; Start-Sleep -Seconds 2; continue }
    }
    try {
      $s = $sp.ReadExisting()
      if ($s.Length -gt 0) {
        $t = (Get-Date).ToUniversalTime().ToString("HH:mm:ss.fff")
        $parts = $s.Split("`n")
        for ($i = 0; $i -lt $parts.Length; $i++) {
          if ($i -gt 0) { $w.Write("`n"); $bol = $true }
          if ($parts[$i].Length -gt 0) {
            if ($bol) { $w.Write("[$t] "); $bol = $false }
            $w.Write($parts[$i])
          }
        }
      } else { Start-Sleep -Milliseconds 50 }
    } catch {
      $w.WriteLine("`n===== $Port dropped $(Get-Date -Format o): $($_.Exception.Message) =====")
      try { $sp.Close() } catch {}
      $sp = $null; $bol = $true
      Start-Sleep -Seconds 2
    }
  }
} finally {
  if ($sp -and $sp.IsOpen) { $sp.Close() }
  $w.WriteLine("`n===== $Port logger ended $(Get-Date -Format o) =====")
  $w.Close()
}
