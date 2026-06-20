Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = "Easy SSD Tester"
$script:AppVersion = "Version 1.0 - 2026"
$script:CopyrightLine = ("Copyright by Dr. Ren" + [char]0x00E9 + " B" + [char]0x00E4 + "der (PhDs)")
$script:LicenseLine = "Freeware kostenlos - Public GNU / GNU GPL v3"
$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:IconPath = Join-Path $script:AppDir "Assets\EasySSDTester.ico"
$script:SelectedDrive = $null
$script:SelectedAnalysis = $null
$script:LastInventoryError = ""

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Fuer vollstaendige SMART-Daten sind Administratorrechte empfohlen. Easy SSD Tester jetzt mit Administratorrechten neu starten?",
        $script:AppName,
        "YesNo",
        "Question"
    )
    if ($answer -eq "Yes") {
        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") -Verb RunAs
            exit
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Erhoehter Start wurde abgebrochen oder ist fehlgeschlagen. Die App laeuft mit eingeschraenkten Daten weiter.", $script:AppName, "OK", "Information") | Out-Null
        }
    }
}

function Find-SmartCtl {
    $local = Join-Path $script:AppDir "Tools\smartctl.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command "smartctl.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-SmartCtl {
    param([string[]]$Arguments)
    $smartctl = Find-SmartCtl
    if (-not $smartctl) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $smartctl
        foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(20000)) {
            try { $p.Kill() } catch {}
            return "smartctl timeout"
        }
        return ($p.StandardOutput.ReadToEnd() + "`r`n" + $p.StandardError.ReadToEnd()).Trim()
    } catch {
        return "smartctl error: $($_.Exception.Message)"
    }
}

function Get-LetterMap {
    $map = @{}
    try {
        $parts = Get-CimInstance Win32_DiskPartition -ErrorAction Stop
        foreach ($part in $parts) {
            $escaped = $part.DeviceID.Replace('\', '\\')
            $letters = Get-CimAssociatedInstance -InputObject $part -Association Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue
            if ($letters) {
                $diskIndex = [int]($part.DiskIndex)
                if (-not $map.ContainsKey($diskIndex)) { $map[$diskIndex] = @() }
                foreach ($letter in $letters) { $map[$diskIndex] += $letter.DeviceID }
            }
        }
    } catch {}
    return $map
}

function Get-DriveInventory {
    $script:LastInventoryError = ""
    $letterMap = Get-LetterMap
    $physical = @{}
    try {
        foreach ($pd in Get-PhysicalDisk -ErrorAction Stop) {
            $physical[[string]$pd.FriendlyName] = $pd
        }
    } catch {}

    $drives = @()
    try {
        $diskDrives = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Sort-Object Index
        foreach ($d in $diskDrives) {
            $model = ([string]$d.Model).Trim()
            $pd = $null
            if ($physical.ContainsKey($model)) { $pd = $physical[$model] }
            $letters = if ($letterMap.ContainsKey([int]$d.Index)) { ($letterMap[[int]$d.Index] | Sort-Object -Unique) -join ", " } else { "" }
            $media = if ($pd -and $pd.MediaType) { [string]$pd.MediaType } elseif ($d.MediaType -match "SSD") { "SSD" } else { "Unknown" }
            $bus = if ($pd -and $pd.BusType) { [string]$pd.BusType } else { [string]$d.InterfaceType }
            $health = if ($pd -and $pd.HealthStatus) { [string]$pd.HealthStatus } else { [string]$d.Status }
            $drives += [pscustomobject]@{
                Index = [int]$d.Index
                DeviceId = [string]$d.DeviceID
                SmartDevice = "/dev/pd$($d.Index)"
                Model = $model
                Serial = ([string]$d.SerialNumber).Trim()
                SizeGB = [math]::Round($d.Size / 1GB, 1)
                MediaType = $media
                BusType = $bus
                HealthStatus = $health
                Letters = $letters
                Firmware = [string]$d.FirmwareRevision
            }
        }
    } catch {
        $script:LastInventoryError = "CIM-Zugriff fehlgeschlagen: $($_.Exception.Message)"
    }

    if ($drives.Count -eq 0) {
        try {
            $diskList = Get-Disk -ErrorAction Stop | Sort-Object Number
            foreach ($disk in $diskList) {
                $letters = ""
                try {
                    $volumes = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue
                    $letters = ($volumes | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" } | Sort-Object -Unique) -join ", "
                } catch {}
                $drives += [pscustomobject]@{
                    Index = [int]$disk.Number
                    DeviceId = "\\.\PhysicalDrive$($disk.Number)"
                    SmartDevice = "/dev/pd$($disk.Number)"
                    Model = ([string]$disk.FriendlyName).Trim()
                    Serial = ([string]$disk.SerialNumber).Trim()
                    SizeGB = [math]::Round($disk.Size / 1GB, 1)
                    MediaType = if ($disk.MediaType) { [string]$disk.MediaType } else { "Unknown" }
                    BusType = [string]$disk.BusType
                    HealthStatus = [string]$disk.HealthStatus
                    Letters = $letters
                    Firmware = ""
                }
            }
            if ($drives.Count -gt 0 -and $script:LastInventoryError) {
                $script:LastInventoryError += " Fallback ueber Get-Disk erfolgreich."
            }
        } catch {
            if ($script:LastInventoryError) { $script:LastInventoryError += " " }
            $script:LastInventoryError += "Get-Disk-Fallback fehlgeschlagen: $($_.Exception.Message)"
        }
    }
    return $drives
}

function Detect-Vendor {
    param([string]$Model)
    $m = $Model.ToLowerInvariant()
    $vendors = @(
        "samsung", "crucial", "micron", "western digital", "wd", "sandisk", "kingston",
        "seagate", "toshiba", "kioxia", "intel", "sk hynix", "hynix", "liteon",
        "hp", "lenovo", "intenso", "innovationit", "adata", "transcend", "corsair",
        "patriot", "lexar", "pny", "teamgroup", "verbatim"
    )
    foreach ($v in $vendors) {
        if ($m.Contains($v)) { return (Get-Culture).TextInfo.ToTitleCase($v) }
    }
    return "Unbekannt"
}

function Parse-FirstNumber {
    param([string]$Text, [string]$Pattern)
    $match = [regex]::Match($Text, $Pattern, "IgnoreCase")
    if ($match.Success) {
        $num = $match.Groups[1].Value.Replace(",", ".")
        $out = 0.0
        if ([double]::TryParse($num, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$out)) { return $out }
    }
    return $null
}

function Parse-SmartAttribute {
    param([string]$Text, [string]$NamePattern)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match $NamePattern) {
            $nums = [regex]::Matches($line, "[-]?\d+")
            if ($nums.Count -gt 0) { return [double]$nums[$nums.Count - 1].Value }
        }
    }
    return $null
}

function Get-StorageReliability {
    param([object]$Drive)
    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.FriendlyName -eq $Drive.Model } | Select-Object -First 1
        if ($pd) {
            return $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        }
    } catch {}
    return $null
}

function Analyze-Drive {
    param([object]$Drive)
    $smartText = Invoke-SmartCtl @("-a", $Drive.SmartDevice)
    if (-not $smartText) { $smartText = Invoke-SmartCtl @("-a", $Drive.DeviceId) }
    $rel = Get-StorageReliability $Drive

    $metrics = [ordered]@{}
    $metrics["Modell"] = $Drive.Model
    $metrics["Hersteller"] = Detect-Vendor $Drive.Model
    $metrics["Seriennummer"] = $Drive.Serial
    $metrics["Groesse"] = "$($Drive.SizeGB) GB"
    $metrics["Bus"] = $Drive.BusType
    $metrics["Medientyp"] = $Drive.MediaType
    $metrics["Laufwerksbuchstaben"] = $Drive.Letters
    $metrics["Windows Health"] = $Drive.HealthStatus

    $temperature = $null
    $powerHours = $null
    $percentUsed = $null
    $availableSpare = $null
    $mediaErrors = $null
    $crcErrors = $null
    $reallocated = $null
    $tbWritten = $null
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($rel) {
        if ($rel.Temperature) { $temperature = [double]$rel.Temperature }
        if ($rel.PowerOnHours) { $powerHours = [double]$rel.PowerOnHours }
        if ($rel.Wear) { $percentUsed = [double]$rel.Wear }
        if ($rel.ReadErrorsTotal) { $mediaErrors = [double]$rel.ReadErrorsTotal }
        if ($rel.WriteErrorsTotal -and -not $mediaErrors) { $mediaErrors = [double]$rel.WriteErrorsTotal }
    }

    if ($smartText) {
        $nvmeTemp = Parse-FirstNumber $smartText "Temperature:\s+([0-9]+)\s+Celsius"
        if ($nvmeTemp -ne $null) { $temperature = $nvmeTemp }
        $nvmeHours = Parse-FirstNumber $smartText "Power On Hours:\s+([0-9,]+)"
        if ($nvmeHours -ne $null) { $powerHours = $nvmeHours }
        $nvmeUsed = Parse-FirstNumber $smartText "Percentage Used:\s+([0-9]+)%"
        if ($nvmeUsed -ne $null) { $percentUsed = $nvmeUsed }
        $spare = Parse-FirstNumber $smartText "Available Spare:\s+([0-9]+)%"
        if ($spare -ne $null) { $availableSpare = $spare }
        $nvmeErr = Parse-FirstNumber $smartText "Media and Data Integrity Errors:\s+([0-9,]+)"
        if ($nvmeErr -ne $null) { $mediaErrors = $nvmeErr }
        $unitsWritten = Parse-FirstNumber $smartText "Data Units Written:\s+([0-9,]+)"
        if ($unitsWritten -ne $null) { $tbWritten = [math]::Round(($unitsWritten * 512000) / 1TB, 2) }

        $ataTemp = Parse-SmartAttribute $smartText "(Temperature_Celsius|Airflow_Temperature|Temperature_Internal)"
        if ($ataTemp -ne $null -and $ataTemp -ge 0 -and $ataTemp -le 100) { $temperature = $ataTemp }
        $ataHours = Parse-SmartAttribute $smartText "Power_On_Hours"
        if ($ataHours -ne $null) { $powerHours = $ataHours }
        $wear = Parse-SmartAttribute $smartText "(Percent_Lifetime_Used|Media_Wearout_Indicator|Wear_Leveling_Count|SSD_Life_Left|Remaining_Lifetime_Perc)"
        if ($wear -ne $null) {
            if ($wear -le 100) {
                if ($smartText -match "(Media_Wearout_Indicator|SSD_Life_Left|Remaining_Lifetime_Perc)") { $percentUsed = 100 - $wear }
                else { $percentUsed = $wear }
            }
        }
        $crc = Parse-SmartAttribute $smartText "UDMA_CRC_Error_Count"
        if ($crc -ne $null) { $crcErrors = $crc }
        $realloc = Parse-SmartAttribute $smartText "(Reallocated_Sector_Ct|Reallocated_Event_Count)"
        if ($realloc -ne $null) { $reallocated = $realloc }
        $lbas = Parse-SmartAttribute $smartText "Total_LBAs_Written"
        if ($lbas -ne $null) { $tbWritten = [math]::Round(($lbas * 512) / 1TB, 2) }

        if ($smartText -match "SMART overall-health self-assessment test result:\s+FAILED") {
            $warnings.Add("SMART meldet einen fehlgeschlagenen Gesamtzustand.")
        }
        if ($smartText -match "SMART support is:\s+Unavailable|SMART Disabled|Unknown USB bridge") {
            $warnings.Add("SMART-Daten sind nicht verfuegbar. Adapter, RAID/RST oder USB-Bridge pruefen.")
        }
    } else {
        $warnings.Add("smartctl.exe wurde nicht gefunden. Detailwerte sind auf Windows-Daten begrenzt.")
    }

    if ($temperature -ne $null) { $metrics["Temperatur"] = "$temperature C" } else { $metrics["Temperatur"] = "k. A." }
    if ($powerHours -ne $null) { $metrics["Betriebsstunden"] = [string][math]::Round($powerHours, 0) } else { $metrics["Betriebsstunden"] = "k. A." }
    if ($percentUsed -ne $null) { $metrics["Verschleiss"] = "$([math]::Round($percentUsed, 0)) %" } else { $metrics["Verschleiss"] = "k. A." }
    if ($availableSpare -ne $null) { $metrics["NVMe Reserve"] = "$availableSpare %" } else { $metrics["NVMe Reserve"] = "k. A." }
    if ($tbWritten -ne $null) { $metrics["Geschrieben"] = "$tbWritten TB" } else { $metrics["Geschrieben"] = "k. A." }
    if ($mediaErrors -ne $null) { $metrics["Medienfehler"] = [string][math]::Round($mediaErrors, 0) } else { $metrics["Medienfehler"] = "k. A." }
    if ($crcErrors -ne $null) { $metrics["CRC Fehler"] = [string][math]::Round($crcErrors, 0) } else { $metrics["CRC Fehler"] = "k. A." }
    if ($reallocated -ne $null) { $metrics["Umgesetzte Bloecke"] = [string][math]::Round($reallocated, 0) } else { $metrics["Umgesetzte Bloecke"] = "k. A." }

    $score = 100
    $basis = "Windows- und SMART-Indikatoren"
    if ($Drive.HealthStatus -match "Unhealthy|Warning|Pred Fail|Error") { $score = [math]::Min($score, 25) }
    if ($percentUsed -ne $null) { $score = [math]::Min($score, [math]::Max(0, 100 - [int]$percentUsed)) }
    elseif ($powerHours -ne $null) {
        if ($powerHours -gt 50000) { $score = [math]::Min($score, 45) }
        elseif ($powerHours -gt 30000) { $score = [math]::Min($score, 65) }
        elseif ($powerHours -gt 15000) { $score = [math]::Min($score, 80) }
        $basis = "Grobe Schaetzung, weil kein Verschleisswert vorliegt"
    } else {
        $score = [math]::Min($score, 60)
        $basis = "Eingeschraenkt, weil wichtige SMART-Werte fehlen"
    }
    if ($availableSpare -ne $null -and $availableSpare -lt 10) { $score = [math]::Min($score, 30); $warnings.Add("NVMe-Reserve ist niedrig.") }
    if ($temperature -ne $null -and $temperature -ge 60) { $score = [math]::Min($score, 55); $warnings.Add("Temperatur ist hoch.") }
    if ($mediaErrors -ne $null -and $mediaErrors -gt 0) { $score = [math]::Min($score, 35); $warnings.Add("Medien-/Datenfehler vorhanden.") }
    if ($reallocated -ne $null -and $reallocated -gt 0) { $score = [math]::Min($score, 50); $warnings.Add("Umgesetzte Bloecke vorhanden.") }
    if ($crcErrors -ne $null -and $crcErrors -gt 0) { $warnings.Add("CRC-Fehler deuten oft auf Kabel, Adapter oder Port hin.") }

    $verdict = "Sehr gut"
    $color = [System.Drawing.Color]::FromArgb(31, 132, 73)
    if ($score -lt 20) { $verdict = "Tauschen"; $color = [System.Drawing.Color]::FromArgb(192, 57, 43) }
    elseif ($score -lt 40) { $verdict = "Vorsicht"; $color = [System.Drawing.Color]::FromArgb(211, 84, 0) }
    elseif ($score -lt 80) { $verdict = "Noch gut"; $color = [System.Drawing.Color]::FromArgb(181, 137, 0) }
    if ($metrics["Verschleiss"] -eq "k. A." -and $smartText -eq $null) { $verdict = "Keine Daten"; $color = [System.Drawing.Color]::Gray }

    if ($warnings.Count -eq 0) { $warnings.Add("Keine kritischen Hinweise erkannt.") }

    return [pscustomobject]@{
        Drive = $Drive
        Metrics = $metrics
        Score = [int]$score
        Verdict = $verdict
        Color = $color
        Basis = $basis
        Warnings = @($warnings)
        SmartText = if ($smartText) { $smartText } else { "smartctl.exe nicht gefunden." }
        Time = Get-Date
    }
}

function HtmlEncode {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Export-Report {
    param([object]$Analysis, [string]$Path)
    $rows = ""
    foreach ($key in $Analysis.Metrics.Keys) {
        $rows += "<tr><th>$(HtmlEncode $key)</th><td>$(HtmlEncode ([string]$Analysis.Metrics[$key]))</td></tr>`n"
    }
    $warn = ($Analysis.Warnings | ForEach-Object { "<li>$(HtmlEncode $_)</li>" }) -join "`n"
    $html = @"
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>Easy SSD Tester Bericht</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#1f2933;background:#f7f8fa}
main{max-width:920px;margin:auto;background:#fff;border:1px solid #d7dde5;padding:28px}
h1{margin:0 0 4px;font-size:26px} .sub{color:#56616f;margin-bottom:22px}
.badge{display:inline-block;background:$(if($Analysis.Score -lt 20){"#c0392b"}elseif($Analysis.Score -lt 40){"#d35400"}elseif($Analysis.Score -lt 80){"#b58900"}else{"#1f8449"});color:#fff;padding:10px 14px;border-radius:4px;font-weight:700}
table{border-collapse:collapse;width:100%;margin-top:18px} th,td{border-bottom:1px solid #e4e8ee;text-align:left;padding:9px 10px} th{width:240px;background:#f1f4f8}
.box{background:#eef6ff;border-left:4px solid #2f80ed;padding:12px 14px;margin:18px 0}
footer{margin-top:24px;color:#56616f;font-size:12px}
@media print{body{background:#fff;margin:0}main{border:0}}
</style>
</head>
<body>
<main>
<h1>Easy SSD Tester Bericht</h1>
<div class="sub">$($script:AppVersion) | $(HtmlEncode $($Analysis.Time.ToString("yyyy-MM-dd HH:mm")))</div>
<div class="badge">$(HtmlEncode $Analysis.Verdict) - $($Analysis.Score)%</div>
<div class="box">Bewertungsbasis: $(HtmlEncode $Analysis.Basis)</div>
<table>$rows</table>
<h2>Hinweise</h2>
<ul>$warn</ul>
<footer>
$($script:CopyrightLine)<br>
$($script:LicenseLine)<br>
Dieses Ergebnis ist eine technische Einschaetzung aus verfuegbaren Windows-/SMART-Daten und keine Garantie gegen Ausfall.
</footer>
</main>
</body>
</html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

function Run-SpeedTest {
    param([string]$Root, [int]$MegaBytes)
    $file = Join-Path $Root "easy_ssd_tester_speed.tmp"
    $bufferSize = 4MB
    $buffer = New-Object byte[] $bufferSize
    (New-Object Random).NextBytes($buffer)
    $chunks = [math]::Max(1, [int](($MegaBytes * 1MB) / $bufferSize))
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $fs = [IO.File]::Open($file, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        for ($i = 0; $i -lt $chunks; $i++) { $fs.Write($buffer, 0, $buffer.Length) }
        $fs.Flush($true)
        $fs.Close()
        $sw.Stop()
        $write = [math]::Round($MegaBytes / [math]::Max($sw.Elapsed.TotalSeconds, 0.01), 1)

        $readBuffer = New-Object byte[] $bufferSize
        $sw.Restart()
        $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        while ($fs.Read($readBuffer, 0, $readBuffer.Length) -gt 0) {}
        $fs.Close()
        $sw.Stop()
        $read = [math]::Round($MegaBytes / [math]::Max($sw.Elapsed.TotalSeconds, 0.01), 1)
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ReadMBs = $read; WriteMBs = $write; Error = $null }
    } catch {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ReadMBs = 0; WriteMBs = 0; Error = $_.Exception.Message }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "$script:AppName - $script:AppVersion"
$form.Size = New-Object System.Drawing.Size(1120, 760)
$form.MinimumSize = New-Object System.Drawing.Size(980, 650)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
if (Test-Path $script:IconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch {}
}

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 86
$header.BackColor = [System.Drawing.Color]::FromArgb(32, 44, 57)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = $script:AppName
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Segoe UI", 21, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 12)
$title.AutoSize = $true
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "$script:AppVersion | $script:CopyrightLine | $script:LicenseLine"
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(218, 225, 232)
$subtitle.Location = New-Object System.Drawing.Point(22, 54)
$subtitle.AutoSize = $true
$header.Controls.Add($subtitle)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(0, 86)
$tabs.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - 86))
$tabs.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($tabs)

$tabOverview = New-Object System.Windows.Forms.TabPage
$tabOverview.Text = "Uebersicht"
$tabSmart = New-Object System.Windows.Forms.TabPage
$tabSmart.Text = "SMART Details"
$tabSpeed = New-Object System.Windows.Forms.TabPage
$tabSpeed.Text = "Geschwindigkeit"
$tabReport = New-Object System.Windows.Forms.TabPage
$tabReport.Text = "Bericht"
$tabInfo = New-Object System.Windows.Forms.TabPage
$tabInfo.Text = "Info"
[void]$tabs.TabPages.AddRange(@($tabOverview, $tabSmart, $tabSpeed, $tabReport, $tabInfo))

$driveGrid = New-Object System.Windows.Forms.DataGridView
$driveGrid.Location = New-Object System.Drawing.Point(16, 16)
$driveGrid.Size = New-Object System.Drawing.Size(650, 520)
$driveGrid.Anchor = "Top,Bottom,Left"
$driveGrid.ReadOnly = $true
$driveGrid.SelectionMode = "FullRowSelect"
$driveGrid.MultiSelect = $false
$driveGrid.AutoSizeColumnsMode = "Fill"
$driveGrid.AllowUserToAddRows = $false
$driveGrid.AllowUserToDeleteRows = $false
$tabOverview.Controls.Add($driveGrid)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Aktualisieren"
$btnRefresh.Location = New-Object System.Drawing.Point(16, 548)
$btnRefresh.Size = New-Object System.Drawing.Size(120, 32)
$btnRefresh.Anchor = "Bottom,Left"
$tabOverview.Controls.Add($btnRefresh)

$btnAnalyze = New-Object System.Windows.Forms.Button
$btnAnalyze.Text = "Pruefen"
$btnAnalyze.Location = New-Object System.Drawing.Point(144, 548)
$btnAnalyze.Size = New-Object System.Drawing.Size(120, 32)
$btnAnalyze.Anchor = "Bottom,Left"
$tabOverview.Controls.Add($btnAnalyze)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Bereit."
$statusLabel.Location = New-Object System.Drawing.Point(280, 554)
$statusLabel.Size = New-Object System.Drawing.Size(390, 24)
$statusLabel.Anchor = "Bottom,Left"
$tabOverview.Controls.Add($statusLabel)

$resultPanel = New-Object System.Windows.Forms.Panel
$resultPanel.Location = New-Object System.Drawing.Point(684, 16)
$resultPanel.Size = New-Object System.Drawing.Size(390, 520)
$resultPanel.Anchor = "Top,Bottom,Left,Right"
$resultPanel.BorderStyle = "FixedSingle"
$tabOverview.Controls.Add($resultPanel)

$verdictLabel = New-Object System.Windows.Forms.Label
$verdictLabel.Text = "Noch keine Pruefung"
$verdictLabel.Font = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
$verdictLabel.ForeColor = [System.Drawing.Color]::White
$verdictLabel.BackColor = [System.Drawing.Color]::Gray
$verdictLabel.TextAlign = "MiddleCenter"
$verdictLabel.Location = New-Object System.Drawing.Point(18, 18)
$verdictLabel.Size = New-Object System.Drawing.Size(350, 84)
$verdictLabel.Anchor = "Top,Left,Right"
$resultPanel.Controls.Add($verdictLabel)

$metricsBox = New-Object System.Windows.Forms.ListView
$metricsBox.Location = New-Object System.Drawing.Point(18, 118)
$metricsBox.Size = New-Object System.Drawing.Size(350, 250)
$metricsBox.Anchor = "Top,Bottom,Left,Right"
$metricsBox.View = "Details"
$metricsBox.FullRowSelect = $true
[void]$metricsBox.Columns.Add("Wert", 155)
[void]$metricsBox.Columns.Add("Ergebnis", 175)
$resultPanel.Controls.Add($metricsBox)

$warningBox = New-Object System.Windows.Forms.TextBox
$warningBox.Multiline = $true
$warningBox.ReadOnly = $true
$warningBox.ScrollBars = "Vertical"
$warningBox.Location = New-Object System.Drawing.Point(18, 384)
$warningBox.Size = New-Object System.Drawing.Size(350, 112)
$warningBox.Anchor = "Bottom,Left,Right"
$resultPanel.Controls.Add($warningBox)

$smartTextBox = New-Object System.Windows.Forms.TextBox
$smartTextBox.Multiline = $true
$smartTextBox.ReadOnly = $true
$smartTextBox.ScrollBars = "Both"
$smartTextBox.WordWrap = $false
$smartTextBox.Dock = "Fill"
$smartTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabSmart.Controls.Add($smartTextBox)

$speedIntro = New-Object System.Windows.Forms.Label
$speedIntro.Text = "Sequenzieller Plausibilitaetstest auf dem ausgewaehlten Laufwerk. Der Test schreibt eine temporaere Datei und loescht sie danach."
$speedIntro.Location = New-Object System.Drawing.Point(18, 18)
$speedIntro.Size = New-Object System.Drawing.Size(880, 38)
$tabSpeed.Controls.Add($speedIntro)

$sizeLabel = New-Object System.Windows.Forms.Label
$sizeLabel.Text = "Testgroesse:"
$sizeLabel.Location = New-Object System.Drawing.Point(18, 72)
$sizeLabel.Size = New-Object System.Drawing.Size(90, 24)
$tabSpeed.Controls.Add($sizeLabel)

$sizeCombo = New-Object System.Windows.Forms.ComboBox
$sizeCombo.DropDownStyle = "DropDownList"
$sizeCombo.Location = New-Object System.Drawing.Point(112, 70)
$sizeCombo.Size = New-Object System.Drawing.Size(120, 24)
[void]$sizeCombo.Items.AddRange(@("64 MB", "128 MB", "512 MB"))
$sizeCombo.SelectedIndex = 1
$tabSpeed.Controls.Add($sizeCombo)

$btnSpeed = New-Object System.Windows.Forms.Button
$btnSpeed.Text = "Speed-Test starten"
$btnSpeed.Location = New-Object System.Drawing.Point(250, 68)
$btnSpeed.Size = New-Object System.Drawing.Size(160, 30)
$tabSpeed.Controls.Add($btnSpeed)

$speedResult = New-Object System.Windows.Forms.Label
$speedResult.Text = "Noch kein Test ausgefuehrt."
$speedResult.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$speedResult.Location = New-Object System.Drawing.Point(18, 122)
$speedResult.Size = New-Object System.Drawing.Size(860, 80)
$tabSpeed.Controls.Add($speedResult)

$reportText = New-Object System.Windows.Forms.TextBox
$reportText.Multiline = $true
$reportText.ReadOnly = $true
$reportText.ScrollBars = "Vertical"
$reportText.Location = New-Object System.Drawing.Point(18, 18)
$reportText.Size = New-Object System.Drawing.Size(850, 460)
$reportText.Anchor = "Top,Bottom,Left,Right"
$tabReport.Controls.Add($reportText)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "HTML-Bericht speichern"
$btnExport.Location = New-Object System.Drawing.Point(18, 494)
$btnExport.Size = New-Object System.Drawing.Size(180, 34)
$btnExport.Anchor = "Bottom,Left"
$tabReport.Controls.Add($btnExport)

$infoText = New-Object System.Windows.Forms.TextBox
$infoText.Multiline = $true
$infoText.ReadOnly = $true
$infoText.ScrollBars = "Vertical"
$infoText.Dock = "Fill"
$infoText.Text = @"
Easy SSD Tester
$script:AppVersion
$script:CopyrightLine
$script:LicenseLine

Freeware kostenlos.

Dieses portable Tool prueft SSDs und Laufwerke mit Windows-Daten und optional mit smartctl.exe.

Hinweise:
- Fuer vollstaendige SMART-/NVMe-Werte smartctl.exe in Tools\smartctl.exe ablegen oder in PATH bereitstellen.
- Bei USB-Adaptern muss SMART-Passthrough unterstuetzt werden.
- RAID/Intel-RST-Konfigurationen koennen SMART-Daten blockieren.
- Der Speed-Test ist eine Plausibilitaetsmessung, kein vollstaendiger Benchmark.
- Ergebnisse sind technische Einschaetzungen und keine Garantie gegen Laufwerksausfall.

Lizenz:
Easy SSD Tester wird als Public GNU / GNU GPL v3 bereitgestellt.
"@
$tabInfo.Controls.Add($infoText)

function Refresh-Grid {
    $statusLabel.Text = "Laufwerke werden gelesen..."
    [System.Windows.Forms.Application]::DoEvents()
    $drives = Get-DriveInventory
    $driveGrid.DataSource = @($drives)
    if ($driveGrid.Rows.Count -gt 0) { $driveGrid.Rows[0].Selected = $true }
    if ($drives.Count -gt 0) {
        $statusLabel.Text = "$($drives.Count) Laufwerk(e) gefunden."
    } elseif ($script:LastInventoryError) {
        $statusLabel.Text = "Keine Laufwerke gefunden. $script:LastInventoryError"
        [System.Windows.Forms.MessageBox]::Show("Keine Laufwerke gefunden.`r`n`r`n$script:LastInventoryError`r`n`r`nBitte als Administrator starten und pruefen, ob Windows Storage/CIM verfuegbar ist.", $script:AppName, "OK", "Warning") | Out-Null
    } else {
        $statusLabel.Text = "Keine Laufwerke gefunden."
    }
}

function Get-SelectedDrive {
    if ($driveGrid.SelectedRows.Count -eq 0) { return $null }
    return $driveGrid.SelectedRows[0].DataBoundItem
}

function Show-Analysis {
    param([object]$Analysis)
    $script:SelectedAnalysis = $Analysis
    $verdictLabel.Text = "$($Analysis.Verdict) - $($Analysis.Score)%"
    $verdictLabel.BackColor = $Analysis.Color
    $metricsBox.Items.Clear()
    foreach ($key in $Analysis.Metrics.Keys) {
        $item = New-Object System.Windows.Forms.ListViewItem($key)
        [void]$item.SubItems.Add([string]$Analysis.Metrics[$key])
        [void]$metricsBox.Items.Add($item)
    }
    $warningBox.Text = ($Analysis.Warnings -join "`r`n")
    $smartTextBox.Text = $Analysis.SmartText
    $reportText.Text = "Easy SSD Tester Bericht`r`n$script:AppVersion`r`n$script:CopyrightLine`r`n$script:LicenseLine`r`n`r`nErgebnis: $($Analysis.Verdict) - $($Analysis.Score)%`r`nBewertungsbasis: $($Analysis.Basis)`r`n`r`n" +
        (($Analysis.Metrics.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "`r`n") +
        "`r`n`r`nHinweise:`r`n" + ($Analysis.Warnings -join "`r`n")
}

$btnRefresh.Add_Click({ Refresh-Grid })

$btnAnalyze.Add_Click({
    $drive = Get-SelectedDrive
    if (-not $drive) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst ein Laufwerk auswaehlen.", $script:AppName, "OK", "Information") | Out-Null
        return
    }
    $form.Cursor = "WaitCursor"
    try {
        $analysis = Analyze-Drive $drive
        Show-Analysis $analysis
        $tabs.SelectedTab = $tabOverview
    } finally {
        $form.Cursor = "Default"
    }
})

$btnSpeed.Add_Click({
    $drive = Get-SelectedDrive
    if (-not $drive -or [string]::IsNullOrWhiteSpace($drive.Letters)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte ein Laufwerk mit Laufwerksbuchstaben auswaehlen.", $script:AppName, "OK", "Information") | Out-Null
        return
    }
    $letter = ($drive.Letters -split ",")[0].Trim()
    $root = "$letter\"
    $mb = [int]($sizeCombo.SelectedItem.ToString().Split(" ")[0])
    $answer = [System.Windows.Forms.MessageBox]::Show("Der Test schreibt temporaer $mb MB nach $root. Starten?", $script:AppName, "YesNo", "Question")
    if ($answer -ne "Yes") { return }
    $form.Cursor = "WaitCursor"
    $btnSpeed.Enabled = $false
    $speedResult.Text = "Test laeuft..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $r = Run-SpeedTest $root $mb
        if ($r.Error) { $speedResult.Text = "Fehler: $($r.Error)" }
        else {
            $speedResult.Text = "Lesen: $($r.ReadMBs) MB/s   Schreiben: $($r.WriteMBs) MB/s"
        }
    } finally {
        $btnSpeed.Enabled = $true
        $form.Cursor = "Default"
    }
})

$btnExport.Add_Click({
    if (-not $script:SelectedAnalysis) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst ein Laufwerk pruefen.", $script:AppName, "OK", "Information") | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "HTML Bericht (*.html)|*.html"
    $safeModel = ($script:SelectedAnalysis.Drive.Model -replace '[^\w\-]+', '_').Trim("_")
    $dlg.FileName = "EasySSDTester_${safeModel}_$(Get-Date -Format yyyyMMdd_HHmm).html"
    if ($dlg.ShowDialog() -eq "OK") {
        Export-Report $script:SelectedAnalysis $dlg.FileName
        [System.Windows.Forms.MessageBox]::Show("Bericht gespeichert:`r`n$($dlg.FileName)", $script:AppName, "OK", "Information") | Out-Null
    }
})

Refresh-Grid
[void][System.Windows.Forms.Application]::Run($form)
