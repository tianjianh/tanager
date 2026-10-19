# Send one break on a serial port: hold its TX line low (Windows' SetCommBreak, as pyserial's send_break uses) for
# Seconds, then release it. The port opens at 115200 8N1 with no flow control and DTR and RTS low, as the loggers open
# it; no data is sent. Stop a logger holding the port first (its .stop file). The port may vanish when the board resets
# (the PMOD's CH340 re-enumerates), so closing it is allowed to fail.
param([string]$Port, [double]$Seconds = 3)
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$sp.Handshake = 'None'; $sp.DtrEnable = $false; $sp.RtsEnable = $false
$sp.Open()
$t0 = Get-Date
$sp.BreakState = $true
Start-Sleep -Milliseconds ([int]($Seconds * 1000))
$sp.BreakState = $false
$t1 = Get-Date
"break on $Port from $($t0.ToString('o')) to $($t1.ToString('o')) ($([math]::Round(($t1 - $t0).TotalSeconds, 3)) s)"
try { $sp.Close() } catch { "closing ${Port}: $($_.Exception.Message)" }
