# serial_expect.ps1 (D3) with paced typing: a scripted serial session (115200 8N1, no flow control) that logs every
# received byte to -Log and runs -Steps, lines "expect|REGEX|SECONDS", "send|TEXT" (sent with a CR, one character
# every -CharDelayMs, so a polled UART's small RX FIFO keeps up) or "pause|SECONDS". An expect that times out ends the
# run with exit code 2 (the log says which). Lines starting with # are skipped. After the last step it keeps logging
# for -TailSeconds. Nothing in TEXT is interpreted ($ and quotes go to the far end as typed).
param([string]$Port = 'COM7', [string]$Log, [string]$Steps, [int]$TailSeconds = 5, [int]$CharDelayMs = 3)
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
    if ($s.Length -gt 0) { $w.Write($s); [void]$seen.Append($s) } else { Start-Sleep -Milliseconds 20 }
  }
}
$rc = 0
try {
  $sp.Open()
  :steps foreach ($line in Get-Content $Steps) {
    if ($line -match '^\s*(#|$)') { continue }
    $i = $line.IndexOf('|'); $j = $line.LastIndexOf('|')
    $f = @($line.Substring(0, [Math]::Max($i, 0)), $line.Substring($i + 1), '')
    if ($line.StartsWith('expect|')) { $f = @('expect', $line.Substring($i + 1, $j - $i - 1), $line.Substring($j + 1)) }
    switch ($f[0]) {
      'expect' {
        # On a match only the text up to its end is consumed: what came after it in the same read (a prompt right
        # behind "bytes read") stays for the next expect
        $re = $f[1]; $end = (Get-Date).AddSeconds([double]$f[2]); $m = $null
        while ((Get-Date) -lt $end) {
          $m = [regex]::Match($seen.ToString(), $re); if ($m.Success) { break }
          $s = $sp.ReadExisting()
          if ($s.Length -gt 0) { $w.Write($s); [void]$seen.Append($s) } else { Start-Sleep -Milliseconds 20 }
        }
        if (-not ($m -and $m.Success)) { $w.WriteLine("`n===== EXPECT TIMEOUT after $($f[2]) s: $re ====="); $rc = 2; break steps }
        $rest = $seen.ToString().Substring($m.Index + $m.Length); [void]$seen.Clear(); [void]$seen.Append($rest)
      }
      'send' {
        # text from before the send must not satisfy the next expect: let the far end finish (a second prompt can
        # trail the first by a few hundred ms), then forget it. Typeahead is not safe: sudo discards pending input.
        Pump 0.7
        [void]$seen.Clear()
        foreach ($ch in ($f[1] + "`r").ToCharArray()) {
          $sp.Write([string]$ch)
          if ($CharDelayMs -gt 0) { Start-Sleep -Milliseconds $CharDelayMs }
          $s = $sp.ReadExisting(); if ($s.Length -gt 0) { $w.Write($s); [void]$seen.Append($s) }
        }
        Pump 0.3
      }
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
