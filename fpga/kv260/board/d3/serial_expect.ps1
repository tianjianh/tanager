# Scripted serial session (115200 8N1, no flow control): logs every received byte to -Log and runs -Steps, a
# text file of lines "expect|REGEX|SECONDS", "send|TEXT" (sent with a CR; \r and \n are not interpreted) or
# "pause|SECONDS". An expect that times out ends the run with exit code 2 (the log says which); the port is
# then closed. Lines starting with # are skipped. After the last step it keeps logging for -TailSeconds.
param([string]$Port = 'COM7', [string]$Log, [string]$Steps, [int]$TailSeconds = 5)
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$sp.Handshake = 'None'; $sp.DtrEnable = $false; $sp.RtsEnable = $false
$sp.Encoding = [System.Text.Encoding]::UTF8; $sp.ReadTimeout = 200
$w = New-Object System.IO.StreamWriter($Log, $true, [System.Text.Encoding]::UTF8)
$w.AutoFlush = $true
$w.WriteLine("`n===== $Port scripted session opened $(Get-Date -Format o) =====")
$seen = New-Object System.Text.StringBuilder   # text received since the last matched expect
function Pump([double]$secs) {
  $end = (Get-Date).AddSeconds($secs)
  while ((Get-Date) -lt $end) {
    $s = $sp.ReadExisting()
    if ($s.Length -gt 0) { $w.Write($s); [void]$seen.Append($s) } else { Start-Sleep -Milliseconds 50 }
  }
}
$rc = 0
try {
  $sp.Open()
  foreach ($line in Get-Content $Steps) {
    if ($line -match '^\s*(#|$)') { continue }
    $f = $line -split '\|', 3
    switch ($f[0]) {
      'expect' {
        $re = $f[1]; $end = (Get-Date).AddSeconds([double]$f[2]); $ok = $false
        while ((Get-Date) -lt $end) {
          if ($seen.ToString() -match $re) { $ok = $true; break }
          $s = $sp.ReadExisting()
          if ($s.Length -gt 0) { $w.Write($s); [void]$seen.Append($s) } else { Start-Sleep -Milliseconds 50 }
        }
        if (-not $ok) { $w.WriteLine("`n===== EXPECT TIMEOUT after $($f[2]) s: $re ====="); $rc = 2; break }
        [void]$seen.Clear()
      }
      'send'  { $sp.Write($f[1] + "`r"); Pump 0.3 }
      'pause' { Pump ([double]$f[1]) }
    }
  }
  Pump $TailSeconds
} catch {
  $w.WriteLine("`n===== $Port error: $($_.Exception.Message) ====="); $rc = 3
} finally {
  if ($sp.IsOpen) { $sp.Close() }
  $w.WriteLine("`n===== $Port scripted session closed $(Get-Date -Format o), exit $rc =====")
  $w.Close()
}
exit $rc
