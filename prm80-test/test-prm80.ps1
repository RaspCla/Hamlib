# Hardware test of the Hamlib prm80 backend (PRM80 firmware V5.x)
#
# Starts rigctld.exe from this folder and talks to it with the Hamlib network
# protocol ("+" extended answers).
#
# 1. Standard tests (default): a fixed set of checks with OK / FAIL.
#    Your own channels are not changed: only a new channel directly after the
#    last one is written (channel number = last channel + 1).
#
# 2. Command list (-Commands file.txt): runs the rigctl commands of a text
#    file one after the other and logs every answer. Hamlib developers can
#    send such a file to have something checked on real hardware.
#    File format, one command per line:
#      # comment            shown in the log as a heading
#      E 3                  any rigctl / rigctld command
#      wait 500             pause in milliseconds
#      {NEW}  {LAST}        replaced by the new test channel / the last channel
#    Example:
#      # check reverse on channel 3
#      E 3
#      U REV 1
#      f
#      U REV 0
#
# Usage: test-prm80.bat                          (asks for port and last channel)
#        test-prm80.bat -Commands mytest.txt
#    or: powershell -ExecutionPolicy Bypass -File test-prm80.ps1 -Com COM3 -LastChannel 47
#
# Results: test-prm80-log.txt (all commands and answers),
#          test-prm80-rigctld.txt (debug output of rigctld, -vvvv)

param(
    [string]$Com = "",
    [int]$LastChannel = -1,
    [string]$Commands = "",
    [string]$Rigctld = "",
    [int]$Port = 4532,
    [int]$Model = 28001
)

$ScriptVersion = "2026-10-27"
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $here "test-prm80-log.txt"
$daemonOut = Join-Path $here "test-prm80-rigctld.txt"
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$results = New-Object System.Collections.ArrayList
$script:wrote = $false

function Log([string]$text) {
    Add-Content -Path $logFile -Value $text -Encoding UTF8
}

function Show([string]$text, [string]$color = "Gray") {
    Write-Host $text -ForegroundColor $color
    Log $text
}

function Result([string]$name, [bool]$ok, [string]$detail) {
    $status = "FAIL"
    $color = "Red"
    if ($ok) { $status = "OK"; $color = "Green" }
    [void]$results.Add([pscustomobject]@{ Test = $name; Result = $status; Details = $detail })
    Show ("  {0,-5} {1}  {2}" -f $status, $name, $detail) $color
}

# ---- Input ------------------------------------------------------------------

$commandLines = $null
if ($Commands -ne "") {
    if (-not [System.IO.Path]::IsPathRooted($Commands) -and -not (Test-Path $Commands)) {
        $Commands = Join-Path $here $Commands
    }
    if (-not (Test-Path $Commands)) {
        Write-Host ("Command file not found: " + $Commands) -ForegroundColor Red
        exit 1
    }
    $commandLines = @(Get-Content -Path $Commands)
}

if ($Com -eq "") {
    $Com = Read-Host "COM port of the PRM80 (e.g. COM3)"
}
$Com = $Com.Trim()
if ($Com -match '^\d+$') { $Com = "COM" + $Com }      # "15" -> "COM15"

# the last channel is needed for the standard tests and for {NEW} / {LAST}
$needLast = $true
if ($null -ne $commandLines) {
    # placeholders in commands (not in comments) need the last channel
    $cmdText = ($commandLines | Where-Object { -not $_.Trim().StartsWith("#") }) -join "`n"
    $needLast = $cmdText -match '\{NEW\}|\{LAST\}'
}
if ($needLast -and $LastChannel -lt 0) {
    $LastChannel = [int](Read-Host "Number of the last channel in the PRM80 (see channel manager, e.g. 47)")
}
$testChan = $LastChannel + 1
if ($needLast -and $testChan -gt 99) {
    Write-Host "All 100 channels are used - the test needs a free channel." -ForegroundColor Red
    exit 1
}
if ($Rigctld -eq "") {
    $Rigctld = Join-Path $here "rigctld.exe"
}

Set-Content -Path $logFile -Value ("PRM80 Hamlib test " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") `
    + ", script " + $ScriptVersion) -Encoding UTF8
if ($null -ne $commandLines) {
    Show ("Port {0}, command file {1}" -f $Com, $Commands)
} else {
    Show ("Port {0}, last channel {1}, test channel {2} (will be created)" -f $Com, $LastChannel, $testChan)
}
Show "Close the PRM80 control software first. The radio must not transmit."
Show ""

# ---- Start rigctld ----------------------------------------------------------

if (-not (Test-Path $Rigctld)) {
    Show ("rigctld not found: " + $Rigctld) "Red"
    exit 1
}
$version = & $Rigctld --version 2>&1 | Out-String
Show ("rigctld: " + $version.Trim())

$daemonArgs = @("-m", "$Model", "-r", $Com, "-t", "$Port", "-vvvv")
$proc = Start-Process -FilePath $Rigctld -ArgumentList $daemonArgs -PassThru -NoNewWindow `
        -RedirectStandardError $daemonOut -RedirectStandardOutput ($daemonOut + ".out")

$client = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if ($proc.HasExited) { break }
    try {
        $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $Port)
        break
    } catch {
        $client = $null
    }
}
if ($client -eq $null) {
    Show "rigctld could not open the radio. Last lines of its output:" "Red"
    if (Test-Path $daemonOut) {
        Get-Content $daemonOut -Tail 15 | ForEach-Object { Show ("    " + $_) "Red" }
    }
    if (-not $proc.HasExited) { $proc.Kill() }
    exit 1
}

$stream = $client.GetStream()
$stream.ReadTimeout = 15000
$reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
$writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::ASCII)
$writer.NewLine = "`n"
$writer.AutoFlush = $true

# Command in the extended protocol ("+"): answer lines up to "RPRT n"
function Cmd([string]$command) {
    Log ("> " + $command)
    $writer.WriteLine("+" + $command)
    $lines = New-Object System.Collections.ArrayList
    $rprt = $null
    while ($true) {
        $line = $reader.ReadLine()
        if ($line -eq $null) { throw "Connection to rigctld lost" }
        Log ("  " + $line)
        # "RPRT n" ends the answer (with "H" at the end of the prompt line)
        if ($line -match '(^|\s)RPRT (-?\d+)\s*$') { $rprt = [int]$Matches[2]; break }
        [void]$lines.Add($line)
    }
    return [pscustomobject]@{ Ok = ($rprt -eq 0); Code = $rprt; Lines = $lines; Text = ($lines -join "`n") }
}

function Value($answer, [string]$key) {
    foreach ($l in $answer.Lines) {
        if ($l -match ('^' + [regex]::Escape($key) + ':\s*(.*)$')) { return $Matches[1].Trim() }
    }
    return $null
}

# "Freq:   145.6000000 MHz" -> Hz
function Mhz($answer, [string]$key) {
    if ($answer.Text -cmatch ('(?m)^' + [regex]::Escape($key) + ':\s+([0-9.]+) MHz')) {
        return [long][math]::Round([double]::Parse($Matches[1], $culture) * 1000000)
    }
    return -1
}

function Channel($answer) {
    # -cmatch: case sensitive, "get_channel: n" is the echo of the command
    if ($answer.Text -cmatch '(?m)^Channel: (\d+)') { return [int]$Matches[1] }
    return -1
}

# "Offset: +600.0000 kHz" -> Hz
function Offset($answer) {
    if ($answer.Text -cmatch 'Offset: \+?(-?[0-9.]+) (Hz|kHz|MHz)') {
        $v = [double]::Parse($Matches[1], $culture)
        switch ($Matches[2]) { "kHz" { $v *= 1000 } "MHz" { $v *= 1000000 } }
        return [long][math]::Round($v)
    }
    return -1
}

function IsRev($answer) {
    return $answer.Text -cmatch 'Functions:.*\bREV\b'
}

function F([long]$hz) {
    return ($hz / 1000000.0).ToString("0.0000", $culture)
}

function RevText([bool]$rev) {
    if ($rev) { return " REV" }
    return ""
}

# Write the test channel and read it back with the state of the radio
# (RX/TX come from the PLL values of the PRM80, independent of Hamlib)
function TestChannel([string]$name, [long]$freq, [string]$shift, [long]$offs, [string]$funcs, [int]$flags,
                     [long]$expRx, [long]$expTx, [bool]$expRev) {
    $script:wrote = $true
    $set = Cmd ("H {0} {1} {2} {3} {4} {5}" -f $testChan, $freq, $shift, $offs, $funcs, $flags)
    if (-not $set.Ok) { Result $name $false ("write: RPRT " + $set.Code); return }
    $get = Cmd ("h {0} 1" -f $testChan)
    $ch = Channel $get
    $rx = Mhz $get "Freq"
    $tx = Mhz $get "txFreq"
    $rev = IsRev $get
    $detail = "channel {0}: RX {1} TX {2}{3}" -f $ch, (F $rx), (F $tx), (RevText $rev)
    if ($expTx -lt 0) {
        # shift 0 = default shift of the radio (configuration), value not known
        $ok = $get.Ok -and $ch -eq $testChan -and $rx -eq $expRx -and $tx -lt $rx -and -not $rev
        Result $name $ok ($detail + " (default shift {0} kHz)" -f (($rx - $tx) / 1000))
        return
    }
    $ok = $get.Ok -and $ch -eq $testChan -and $rx -eq $expRx -and $tx -eq $expTx -and $rev -eq $expRev
    if (-not $ok) {
        $detail += " - expected RX {0} TX {1}{2}" -f (F $expRx), (F $expTx), (RevText $expRev)
    }
    Result $name $ok $detail
}

# Round trip: read the test channel, write back exactly what was read, read
# again - the channel must not change (review of Hamlib PR #2285).
# "h" does not show the skip flag, so it is not checked here.
function RoundTrip([string]$name) {
    $g1 = Cmd ("h {0} 1" -f $testChan)
    $rx1 = Mhz $g1 "Freq"
    $tx1 = Mhz $g1 "txFreq"
    $rev1 = IsRev $g1
    $sign = "0"
    if ($g1.Text -cmatch 'Shift: ([+-]),') { $sign = $Matches[1] }
    $offs = Offset $g1
    $funcs = "0"
    if ($rev1) { $funcs = "80000" }
    $set = Cmd ("H {0} {1} {2} {3} {4} 0" -f $testChan, $rx1, $sign, $offs, $funcs)
    $g2 = Cmd ("h {0} 1" -f $testChan)
    $rx2 = Mhz $g2 "Freq"
    $tx2 = Mhz $g2 "txFreq"
    $rev2 = IsRev $g2
    $ok = $set.Ok -and $rx1 -gt 0 -and $rx2 -eq $rx1 -and $tx2 -eq $tx1 -and $rev2 -eq $rev1
    $detail = "read RX {0} TX {1}{2}, written back: RX {3} TX {4}{5}" -f (F $rx1), (F $tx1), (RevText $rev1), `
        (F $rx2), (F $tx2), (RevText $rev2)
    if (-not $set.Ok) { $detail += " (write: RPRT " + $set.Code + ")" }
    Result $name $ok $detail
}

# ---- Command list -----------------------------------------------------------

function RunCommandList() {
    Show ""
    Show ("Commands from " + (Split-Path -Leaf $Commands) + ":")
    $n = 0
    $lastWasComment = $false
    foreach ($raw in $commandLines) {
        $line = $raw.Trim()
        if ($line -eq "") { $lastWasComment = $false; continue }
        if ($line.StartsWith("#")) {
            if (-not $lastWasComment) { Show "" }
            Show $line "Cyan"
            $lastWasComment = $true
            continue
        }
        $lastWasComment = $false
        $line = $line.Replace("{NEW}", "$testChan").Replace("{LAST}", "$LastChannel")
        if ($line -match '^wait\s+(\d+)$') {
            Log ("> wait " + $Matches[1] + " ms")
            Start-Sleep -Milliseconds ([int]$Matches[1])
            continue
        }
        if ($line -cmatch '^H\s') { $script:wrote = $true }
        $n++
        $a = Cmd $line
        $color = "Gray"
        $status = "RPRT 0"
        if (-not $a.Ok) { $color = "Red"; $status = "RPRT " + $a.Code }
        Show ("> {0}   [{1}]" -f $line, $status) $color
        foreach ($l in $a.Lines) { Show ("    " + $l) }
        [void]$results.Add([pscustomobject]@{ Test = $line; Result = $(if ($a.Ok) { "OK" } else { "FAIL" }); Details = $status })
    }
    Show ""
    Show ("{0} command(s) sent." -f $n)
}

# ---- Standard tests ---------------------------------------------------------

function RunStandardTests() {
    Show ""
    Show "Tests:"

    $a = Cmd "\get_info"
    $info = Value $a "Info"
    Result "Firmware version" ($a.Ok -and $info -match ' V5\.') ("" + $info)

    $a = Cmd "f"
    $startFreq = [long](Value $a "Frequency")
    Result "Read frequency" ($a.Ok -and $startFreq -gt 0) (F $startFreq)
    if ($startFreq -gt 300000000) {
        Show "  Note: 70 cm radio - Hamlib only knows 144-148 MHz for the PRM80 so far, the tests use 2 m frequencies." "Yellow"
    }

    $a = Cmd "E 0"
    $b = Cmd "e"
    Result "Select channel 0" ($a.Ok -and (Value $b "Memory#") -eq "0") ("channel " + (Value $b "Memory#"))

    TestChannel "New channel, shift -600 kHz" 145600000 "-" 600000 "0" 0 145600000 145000000 $false
    RoundTrip "Round trip read/write, -600 kHz"
    TestChannel "Shift +1.6 MHz, skip" 145025000 "+" 1600000 "0" 1 145025000 146625000 $false
    TestChannel "Default shift (shift 0)" 145750000 "-" 0 "0" 0 145750000 -1 $false
    TestChannel "No shift" 144800000 "0" 0 "0" 0 144800000 144800000 $false
    # the frequency of "H" is the RX frequency (as "h" reports it), also with reverse
    TestChannel "Reverse in the channel (-)" 145000000 "-" 600000 "80000" 0 145000000 145600000 $true
    RoundTrip "Round trip read/write, reverse (-)"
    TestChannel "Reverse in the channel (+)" 145625000 "+" 600000 "80000" 0 145625000 145025000 $true
    RoundTrip "Round trip read/write, reverse (+)"
    TestChannel "Reverse off again" 145600000 "-" 600000 "0" 0 145600000 145000000 $false

    # Channel with a gap: the firmware would append it after the last one,
    # Hamlib has to refuse it and must not create anything
    $gap = [math]::Min($testChan + 5, 99)
    if ($gap -gt $testChan + 1) {
        $a = Cmd ("H {0} 144900000 0 0 0 0" -f $gap)
        $b = Cmd ("h {0} 1" -f ($testChan + 1))
        $c = Channel $b
        $created = $c -eq ($testChan + 1)
        $what = "not created"
        if ($created) { $what = "was created!" }
        Result ("Channel {0} with a gap refused" -f $gap) ((-not $a.Ok) -and (-not $created)) `
            ("RPRT {0}, channel {1} {2}" -f $a.Code, ($testChan + 1), $what)
    }

    $a = Cmd ("E {0}" -f $testChan)
    $a = Cmd "U REV 1"
    $b = Cmd "u REV"
    $c = Cmd "f"
    $rx = [long](Value $c "Frequency")
    Result "Reverse on (U REV 1)" ($a.Ok -and $b.Lines[-1] -eq "1" -and $rx -eq 145000000) ("RX " + (F $rx))
    $a = Cmd "U REV 0"
    $b = Cmd "u REV"
    $c = Cmd "f"
    $rx = [long](Value $c "Frequency")
    Result "Reverse off (U REV 0)" ($a.Ok -and $b.Lines[-1] -eq "0" -and $rx -eq 145600000) ("RX " + (F $rx))

    $a = Cmd "F 145437500"
    $b = Cmd "f"
    $rx = [long](Value $b "Frequency")
    Result "Set frequency (VFO)" ($a.Ok -and $rx -eq 145437500) ("RX " + (F $rx))

    $a = Cmd "l RAWSTR"
    $s = $a.Lines[-1]
    Result "S meter (RAWSTR)" ($a.Ok -and $s -match '^\d+$') ("value " + $s)

    $a = Cmd "t"
    Result "PTT state" ($a.Ok -and (Value $a "PTT") -eq "0") ("PTT " + (Value $a "PTT"))

    $a = Cmd "E 0"
}

# ---- Run --------------------------------------------------------------------

try {
    $a = Cmd "\get_info"
    Log ("Firmware: " + (Value $a "Info"))
    if ($null -ne $commandLines) {
        RunCommandList
    } else {
        RunStandardTests
    }
} catch {
    Result "Run" $false $_.Exception.Message
    # the reason from the output of rigctld (e.g. old firmware)
    Start-Sleep -Milliseconds 500
    if (Test-Path $daemonOut) {
        $reason = @(Get-Content $daemonOut | Where-Object { $_ -match 'prm80_open:|not supported|rig_open.*(error|returning)' } | Select-Object -Last 4)
        foreach ($r in $reason) { Show ("    " + $r) "Red" }
        if (($reason -join " ") -match 'Invalid configuration|IO error|Communication timed out') {
            Show ("    -> check the COM port {0} (right port? PRM80 software closed? radio on?)" -f $Com) "Yellow"
        }
    }
} finally {
    try { $writer.WriteLine("q") } catch { }
    $client.Close()
    Start-Sleep -Milliseconds 300
    if (-not $proc.HasExited) { $proc.Kill() }
}

# ---- Summary ----------------------------------------------------------------

$bad = @($results | Where-Object { $_.Result -eq "FAIL" }).Count
Show ""
if ($null -ne $commandLines) {
    if ($bad -eq 0) {
        Show "All commands answered with RPRT 0." "Green"
    } else {
        Show ("{0} command(s) with an error (RPRT not 0)." -f $bad) "Red"
    }
} elseif ($bad -eq 0) {
    Show "All tests passed." "Green"
} else {
    Show ("{0} test(s) failed." -f $bad) "Red"
}
Show ""
if ($script:wrote -and $null -eq $commandLines) {
    Show ("Test channel {0}: check it with 'Read from PRM80' in the PRM80 control software:" -f $testChan)
    Show "  145.6000, shift -, 600 kHz, shift enabled, no reverse, no scan lock."
    Show "Then load your backup and 'Write to PRM80' - the test channel is gone again."
    Show ""
} elseif ($script:wrote) {
    Show "Channels were written: restore your backup with 'Write to PRM80' if needed."
    Show ""
}
Show ("Log: " + $logFile)
Show ("rigctld output: " + $daemonOut)
if ($bad -gt 0) { exit 2 }
exit 0
