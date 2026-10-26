# Test der Hamlib-Korrekturen fuer den PRM80 (Firmware V5.x)
#
# Startet rigctld.exe aus diesem Ordner, schickt die Testbefehle ueber das
# Netzwerkprotokoll von Hamlib und vergleicht die Antworten.
# Die eigenen Kanaele bleiben unveraendert: geschrieben wird nur ein neuer
# Kanal hinter dem letzten (Kanalnummer = hoechster Kanal + 1).
#
# Aufruf: test-prm80.bat  (fragt COM-Port und hoechsten Kanal ab)
#   oder: powershell -ExecutionPolicy Bypass -File test-prm80.ps1 -Com COM3 -LastChannel 47

param(
    [string]$Com = "",
    [int]$LastChannel = -1,
    [string]$Rigctld = "",
    [int]$Port = 4532,
    [int]$Model = 28001
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $here "test-prm80-log.txt"
$daemonOut = Join-Path $here "test-prm80-rigctld.txt"
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$results = New-Object System.Collections.ArrayList

function Log([string]$text) {
    Add-Content -Path $logFile -Value $text -Encoding UTF8
}

function Show([string]$text, [string]$color = "Gray") {
    Write-Host $text -ForegroundColor $color
    Log $text
}

function Result([string]$name, [bool]$ok, [string]$detail) {
    $status = "FEHLER"
    $color = "Red"
    if ($ok) { $status = "OK"; $color = "Green" }
    [void]$results.Add([pscustomobject]@{ Test = $name; Ergebnis = $status; Details = $detail })
    Show ("  {0,-6} {1}  {2}" -f $status, $name, $detail) $color
}

function Info([string]$name, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ Test = $name; Ergebnis = "INFO"; Details = $detail })
    Show ("  {0,-6} {1}  {2}" -f "INFO", $name, $detail) "Cyan"
}

# ---- Eingaben ---------------------------------------------------------------

if ($Com -eq "") {
    $Com = Read-Host "COM-Port des PRM80 (z. B. COM3)"
}
if ($LastChannel -lt 0) {
    $LastChannel = [int](Read-Host "Hoechste belegte Kanalnummer im PRM80 (siehe Kanalmanager, z. B. 47)")
}
$testChan = $LastChannel + 1
if ($testChan -gt 99) {
    Write-Host "Alle 100 Kanaele sind belegt - fuer den Test wird ein freier Kanal gebraucht." -ForegroundColor Red
    exit 1
}
if ($Rigctld -eq "") {
    $Rigctld = Join-Path $here "rigctld.exe"
}

Set-Content -Path $logFile -Value ("PRM80 Hamlib-Test " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8
Show ("Port {0}, hoechster Kanal {1}, Testkanal {2} (wird neu angelegt)" -f $Com, $LastChannel, $testChan)
Show "Die PRM80-Software muss geschlossen sein. Das Geraet darf nicht senden."
Show ""

# ---- rigctld starten --------------------------------------------------------

if (-not (Test-Path $Rigctld)) {
    Show ("rigctld nicht gefunden: " + $Rigctld) "Red"
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
    Show "rigctld konnte das Geraet nicht oeffnen. Letzte Zeilen der Ausgabe:" "Red"
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

# Befehl im erweiterten Protokoll ("+"): Antwortzeilen bis "RPRT n"
function Cmd([string]$command) {
    Log ("> " + $command)
    $writer.WriteLine("+" + $command)
    $lines = New-Object System.Collections.ArrayList
    $rprt = $null
    while ($true) {
        $line = $reader.ReadLine()
        if ($line -eq $null) { throw "Verbindung zu rigctld unterbrochen" }
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
    if ($answer.Text -match ('(?m)^' + [regex]::Escape($key) + ':\s+([0-9.]+) MHz')) {
        return [long][math]::Round([double]::Parse($Matches[1], $culture) * 1000000)
    }
    return -1
}

function Channel($answer) {
    if ($answer.Text -match 'Channel: (\d+)') { return [int]$Matches[1] }
    return -1
}

function F([long]$hz) {
    return ($hz / 1000000.0).ToString("0.0000", $culture)
}

# Kanal schreiben und ueber den Zustand des Geraets zuruecklesen
# (RX/TX kommen aus den PLL-Werten des PRM80, also unabhaengig von Hamlib)
function TestChannel([string]$name, [long]$freq, [string]$shift, [long]$offs, [string]$funcs, [int]$flags,
                     [long]$expRx, [long]$expTx, [bool]$expRev) {
    $set = Cmd ("H {0} {1} {2} {3} {4} {5}" -f $testChan, $freq, $shift, $offs, $funcs, $flags)
    if (-not $set.Ok) { Result $name $false ("Schreiben: RPRT " + $set.Code); return }
    $get = Cmd ("h {0} 1" -f $testChan)
    $ch = Channel $get
    $rx = Mhz $get "Freq"
    $tx = Mhz $get "txFreq"
    $rev = $get.Text -match 'Functions:.*\bREV\b'
    $detail = "Kanal {0}: RX {1} TX {2}{3}" -f $ch, (F $rx), (F $tx), $(if ($rev) { " REV" } else { "" })
    if ($expTx -lt 0) {
        # Shift 0 = Standard-Shift des Geraets (Konfiguration), Wert unbekannt
        $ok = $get.Ok -and $ch -eq $testChan -and $rx -eq $expRx -and $tx -lt $rx -and -not $rev
        Result $name $ok ($detail + " (Standard-Shift {0} kHz)" -f (($rx - $tx) / 1000))
        return
    }
    $ok = $get.Ok -and $ch -eq $testChan -and $rx -eq $expRx -and $tx -eq $expTx -and $rev -eq $expRev
    if (-not $ok) {
        $detail += " - erwartet RX {0} TX {1}{2}" -f (F $expRx), (F $expTx), $(if ($expRev) { " REV" } else { "" })
    }
    Result $name $ok $detail
}

# ---- Tests ------------------------------------------------------------------

try {
    Show ""
    Show "Tests:"

    $a = Cmd "\get_info"
    $info = Value $a "Info"
    Result "Firmware-Version" ($a.Ok -and $info -match ' V5\.') ("" + $info)

    $a = Cmd "f"
    $startFreq = [long](Value $a "Frequency")
    Result "Frequenz lesen" ($a.Ok -and $startFreq -gt 0) (F $startFreq)
    if ($startFreq -gt 300000000) {
        Show "  Hinweis: 70-cm-Geraet - Hamlib kennt fuer den PRM80 bisher nur 144-148 MHz, die Tests nutzen 2-m-Frequenzen." "Yellow"
    }

    $a = Cmd "E 0"
    $b = Cmd "e"
    Result "Kanal 0 waehlen" ($a.Ok -and (Value $b "Memory#") -eq "0") ("Kanal " + (Value $b "Memory#"))

    TestChannel "Neuer Kanal, Shift -600 kHz" 145600000 "-" 600000 "0" 0 145600000 145000000 $false
    TestChannel "Shift +1,6 MHz, Scan-Sperre" 145025000 "+" 1600000 "0" 1 145025000 146625000 $false
    TestChannel "Standard-Shift (Shift 0)" 145750000 "-" 0 "0" 0 145750000 -1 $false
    TestChannel "Ohne Shift" 144800000 "0" 0 "0" 0 144800000 144800000 $false
    TestChannel "Reverse im Kanal" 145600000 "-" 600000 "80000" 0 145000000 145600000 $true
    TestChannel "Reverse wieder aus" 145600000 "-" 600000 "0" 0 145600000 145000000 $false

    $a = Cmd ("E {0}" -f $testChan)
    $a = Cmd "U REV 1"
    $b = Cmd "u REV"
    $c = Cmd "f"
    $rx = [long](Value $c "Frequency")
    Result "Reverse einschalten (U REV 1)" ($a.Ok -and $b.Lines[-1] -eq "1" -and $rx -eq 145000000) ("RX " + (F $rx))
    $a = Cmd "U REV 0"
    $b = Cmd "u REV"
    $c = Cmd "f"
    $rx = [long](Value $c "Frequency")
    Result "Reverse ausschalten (U REV 0)" ($a.Ok -and $b.Lines[-1] -eq "0" -and $rx -eq 145600000) ("RX " + (F $rx))

    $a = Cmd "F 145437500"
    $b = Cmd "f"
    $rx = [long](Value $b "Frequency")
    Result "Frequenz setzen (VFO)" ($a.Ok -and $rx -eq 145437500) ("RX " + (F $rx))

    $a = Cmd "l RAWSTR"
    $s = $a.Lines[-1]
    Result "S-Meter (RAWSTR)" ($a.Ok -and $s -match '^\d+$') ("Wert " + $s)

    $a = Cmd "t"
    Result "PTT-Status" ($a.Ok -and (Value $a "PTT") -eq "0") ("PTT " + (Value $a "PTT"))

    $a = Cmd "E 0"
} catch {
    Result "Ablauf" $false $_.Exception.Message
    # Grund aus der Ausgabe von rigctld (z. B. alte Firmware)
    Start-Sleep -Milliseconds 500
    if (Test-Path $daemonOut) {
        $reason = @(Get-Content $daemonOut | Where-Object { $_ -match 'prm80_open:|not supported|rig_open.*(error|returning)' } | Select-Object -Last 4)
        foreach ($r in $reason) { Show ("    " + $r) "Red" }
    }
} finally {
    try { $writer.WriteLine("q") } catch { }
    $client.Close()
    Start-Sleep -Milliseconds 300
    if (-not $proc.HasExited) { $proc.Kill() }
}

# ---- Zusammenfassung --------------------------------------------------------

$bad = @($results | Where-Object { $_.Ergebnis -eq "FEHLER" }).Count
Show ""
if ($bad -eq 0) {
    Show "Alle Tests bestanden." "Green"
} else {
    Show ("{0} Test(s) fehlgeschlagen." -f $bad) "Red"
}
Show ""
Show ("Testkanal {0}: Bitte in der PRM80-Software mit 'Read from PRM80' pruefen:" -f $testChan)
Show "  145.6000, Shift -, 600 kHz, Shift Enabled, ohne Reverse, ohne Scan Lock."
Show "Danach die Sicherung laden und 'Write to PRM80' - dann ist der Testkanal wieder weg."
Show ""
Show ("Protokoll: " + $logFile)
Show ("Ausgabe von rigctld: " + $daemonOut)
if ($bad -gt 0) { exit 2 }
exit 0
