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
$script:DriveInventory = @()

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

function New-DriveRow {
    param(
        [int]$Index,
        [string]$DeviceId,
        [string]$Model,
        [string]$Serial = "",
        [double]$SizeGB = 0,
        [string]$MediaType = "Unknown",
        [string]$BusType = "Unknown",
        [string]$HealthStatus = "Unknown",
        [string]$Letters = "",
        [string]$Firmware = "",
        [bool]$LogicalOnly = $false
    )
    return [pscustomobject]@{
        Index = $Index
        DeviceId = $DeviceId
        SmartDevice = if ($DeviceId -match "PhysicalDrive(\d+)") { "/dev/pd$($Matches[1])" } else { "/dev/pd$Index" }
        Model = if ([string]::IsNullOrWhiteSpace($Model)) { "Unbekanntes Laufwerk $Index" } else { $Model.Trim() }
        Serial = if ($Serial) { $Serial.Trim() } else { "" }
        SizeGB = [math]::Round($SizeGB, 1)
        MediaType = if ($MediaType) { $MediaType } else { "Unknown" }
        BusType = if ($BusType) { $BusType } else { "Unknown" }
        HealthStatus = if ($HealthStatus) { $HealthStatus } else { "Unknown" }
        Letters = if ($Letters) { $Letters } else { "" }
        Firmware = if ($Firmware) { $Firmware } else { "" }
        LogicalOnly = $LogicalOnly
    }
}

function Add-DriveRow {
    param(
        [System.Collections.ArrayList]$Rows,
        [object]$Row
    )
    foreach ($existing in $Rows) {
        if ($existing.DeviceId -eq $Row.DeviceId) { return }
        if ($existing.Model -eq $Row.Model -and $existing.SizeGB -eq $Row.SizeGB -and $existing.Letters -eq $Row.Letters) { return }
    }
    [void]$Rows.Add($Row)
}

function Get-DriveInventory {
    $script:LastInventoryError = ""
    $letterMap = Get-LetterMap
    $physical = @{}
    $physicalRows = New-Object System.Collections.ArrayList
    try {
        foreach ($pd in Get-PhysicalDisk -ErrorAction Stop) {
            $physical[[string]$pd.FriendlyName] = $pd
            $idx = if ($pd.DeviceId -match "^\d+$") { [int]$pd.DeviceId } else { $physicalRows.Count }
            Add-DriveRow $physicalRows (New-DriveRow `
                -Index $idx `
                -DeviceId "\\.\PhysicalDrive$idx" `
                -Model ([string]$pd.FriendlyName) `
                -Serial ([string]$pd.SerialNumber) `
                -SizeGB ([double]($pd.Size / 1GB)) `
                -MediaType ([string]$pd.MediaType) `
                -BusType ([string]$pd.BusType) `
                -HealthStatus ([string]$pd.HealthStatus))
        }
    } catch {
        $script:LastInventoryError = "Get-PhysicalDisk fehlgeschlagen: $($_.Exception.Message)"
    }

    $drives = New-Object System.Collections.ArrayList
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
            Add-DriveRow $drives (New-DriveRow -Index ([int]$d.Index) -DeviceId ([string]$d.DeviceID) -Model $model -Serial ([string]$d.SerialNumber) -SizeGB ([double]($d.Size / 1GB)) -MediaType $media -BusType $bus -HealthStatus $health -Letters $letters -Firmware ([string]$d.FirmwareRevision))
        }
    } catch {
        if ($script:LastInventoryError) { $script:LastInventoryError += " | " }
        $script:LastInventoryError += "CIM-Zugriff fehlgeschlagen: $($_.Exception.Message)"
    }

    if ($drives.Count -eq 0 -and $physicalRows.Count -gt 0) {
        foreach ($row in $physicalRows) { Add-DriveRow $drives $row }
        if ($script:LastInventoryError) { $script:LastInventoryError += " | " }
        $script:LastInventoryError += "Fallback ueber Get-PhysicalDisk verwendet."
    }

    if ($drives.Count -eq 0) {
        try {
            $wmiDrives = Get-WmiObject Win32_DiskDrive -ErrorAction Stop | Sort-Object Index
            foreach ($d in $wmiDrives) {
                $letters = if ($letterMap.ContainsKey([int]$d.Index)) { ($letterMap[[int]$d.Index] | Sort-Object -Unique) -join ", " } else { "" }
                Add-DriveRow $drives (New-DriveRow -Index ([int]$d.Index) -DeviceId ([string]$d.DeviceID) -Model ([string]$d.Model) -Serial ([string]$d.SerialNumber) -SizeGB ([double]($d.Size / 1GB)) -MediaType ([string]$d.MediaType) -BusType ([string]$d.InterfaceType) -HealthStatus ([string]$d.Status) -Letters $letters -Firmware ([string]$d.FirmwareRevision))
            }
            if ($drives.Count -gt 0 -and $script:LastInventoryError) { $script:LastInventoryError += " | Fallback ueber WMI verwendet." }
        } catch {
            if ($script:LastInventoryError) { $script:LastInventoryError += " | " }
            $script:LastInventoryError += "WMI-Fallback fehlgeschlagen: $($_.Exception.Message)"
        }
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
                Add-DriveRow $drives (New-DriveRow -Index ([int]$disk.Number) -DeviceId "\\.\PhysicalDrive$($disk.Number)" -Model ([string]$disk.FriendlyName) -Serial ([string]$disk.SerialNumber) -SizeGB ([double]($disk.Size / 1GB)) -MediaType ([string]$disk.MediaType) -BusType ([string]$disk.BusType) -HealthStatus ([string]$disk.HealthStatus) -Letters $letters)
            }
            if ($drives.Count -gt 0 -and $script:LastInventoryError) {
                $script:LastInventoryError += " | Fallback ueber Get-Disk verwendet."
            }
        } catch {
            if ($script:LastInventoryError) { $script:LastInventoryError += " " }
            $script:LastInventoryError += "Get-Disk-Fallback fehlgeschlagen: $($_.Exception.Message)"
        }
    }

    if ($drives.Count -eq 0) {
        try {
            $idx = 0
            foreach ($di in [System.IO.DriveInfo]::GetDrives()) {
                if (-not $di.IsReady) { continue }
                if ($di.DriveType -ne [System.IO.DriveType]::Fixed -and $di.DriveType -ne [System.IO.DriveType]::Removable) { continue }
                $letter = $di.Name.TrimEnd('\')
                Add-DriveRow $drives (New-DriveRow -Index $idx -DeviceId $di.Name -Model "Logisches Laufwerk $letter" -SizeGB ([double]($di.TotalSize / 1GB)) -MediaType "Unknown" -BusType ([string]$di.DriveType) -HealthStatus "Unknown" -Letters $letter -LogicalOnly $true)
                $idx++
            }
            if ($drives.Count -gt 0) {
                if ($script:LastInventoryError) { $script:LastInventoryError += " | " }
                $script:LastInventoryError += "Nur logische Laufwerke verfuegbar; SMART-Details koennen eingeschraenkt sein."
            }
        } catch {
            if ($script:LastInventoryError) { $script:LastInventoryError += " | " }
            $script:LastInventoryError += ".NET-Laufwerksfallback fehlgeschlagen: $($_.Exception.Message)"
        }
    }

    return @($drives)
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
    $smartText = $null
    if (-not $Drive.LogicalOnly) {
        $smartText = Invoke-SmartCtl @("-a", $Drive.SmartDevice)
        if (-not $smartText) { $smartText = Invoke-SmartCtl @("-a", $Drive.DeviceId) }
    }
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
    } elseif ($Drive.LogicalOnly) {
        $warnings.Add("Nur logische Windows-Laufwerksdaten verfuegbar. SMART-Details sind fuer dieses Laufwerk nicht direkt auslesbar.")
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
    if ($Drive.LogicalOnly) { $verdict = "Basisdaten"; $color = [System.Drawing.Color]::FromArgb(52, 152, 219) }
    elseif ($metrics["Verschleiss"] -eq "k. A." -and $smartText -eq $null) { $verdict = "Keine Daten"; $color = [System.Drawing.Color]::Gray }

    if ($warnings.Count -eq 0) { $warnings.Add("Keine kritischen Hinweise erkannt.") }

    return [pscustomobject]@{
        Drive = $Drive
        Metrics = $metrics
        Score = [int]$score
        Verdict = $verdict
        Color = $color
        Basis = $basis
        Warnings = @($warnings)
        SmartText = if ($smartText) { $smartText } elseif ($Drive.LogicalOnly) { "Nur logisches Laufwerk. Fuer SMART-Details bitte physisches Laufwerk auswaehlen oder Storage-Zugriff pruefen." } else { "smartctl.exe nicht gefunden." }
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
$driveGrid.Size = New-Object System.Drawing.Size(650, 390)
$driveGrid.Anchor = "Top,Left"
$driveGrid.ReadOnly = $true
$driveGrid.SelectionMode = "FullRowSelect"
$driveGrid.MultiSelect = $false
$driveGrid.AutoGenerateColumns = $false
$driveGrid.AutoSizeColumnsMode = "None"
$driveGrid.AllowUserToAddRows = $false
$driveGrid.AllowUserToDeleteRows = $false
$driveGrid.BackgroundColor = [System.Drawing.Color]::White
$driveGrid.RowHeadersVisible = $false
$driveGrid.ColumnHeadersVisible = $true
$driveGrid.EditMode = "EditProgrammatically"
[void]$driveGrid.Columns.Add("Index", "Nr.")
$driveGrid.Columns["Index"].Width = 42
[void]$driveGrid.Columns.Add("Model", "Modell")
$driveGrid.Columns["Model"].Width = 235
[void]$driveGrid.Columns.Add("SizeGB", "GB")
$driveGrid.Columns["SizeGB"].Width = 70
[void]$driveGrid.Columns.Add("MediaType", "Typ")
$driveGrid.Columns["MediaType"].Width = 75
[void]$driveGrid.Columns.Add("BusType", "Bus")
$driveGrid.Columns["BusType"].Width = 75
[void]$driveGrid.Columns.Add("Letters", "Lw.")
$driveGrid.Columns["Letters"].Width = 70
[void]$driveGrid.Columns.Add("HealthStatus", "Status")
$driveGrid.Columns["HealthStatus"].Width = 80
$tabOverview.Controls.Add($driveGrid)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Aktualisieren"
$btnRefresh.Location = New-Object System.Drawing.Point(16, 424)
$btnRefresh.Size = New-Object System.Drawing.Size(120, 32)
$btnRefresh.Anchor = "Top,Left"
$tabOverview.Controls.Add($btnRefresh)

$btnAnalyze = New-Object System.Windows.Forms.Button
$btnAnalyze.Text = "Pruefen"
$btnAnalyze.Location = New-Object System.Drawing.Point(144, 424)
$btnAnalyze.Size = New-Object System.Drawing.Size(120, 32)
$btnAnalyze.Anchor = "Top,Left"
$tabOverview.Controls.Add($btnAnalyze)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Bereit."
$statusLabel.Location = New-Object System.Drawing.Point(16, 468)
$statusLabel.Size = New-Object System.Drawing.Size(650, 24)
$statusLabel.Anchor = "Top,Left"
$tabOverview.Controls.Add($statusLabel)

$resultPanel = New-Object System.Windows.Forms.Panel
$resultPanel.Location = New-Object System.Drawing.Point(684, 16)
$resultPanel.Size = New-Object System.Drawing.Size(410, 560)
$resultPanel.Anchor = "Top,Bottom,Left,Right"
$resultPanel.BorderStyle = "FixedSingle"
$tabOverview.Controls.Add($resultPanel)

$verdictLabel = New-Object System.Windows.Forms.Label
$verdictLabel.Text = "Noch keine Pruefung"
$verdictLabel.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$verdictLabel.ForeColor = [System.Drawing.Color]::White
$verdictLabel.BackColor = [System.Drawing.Color]::Gray
$verdictLabel.TextAlign = "MiddleCenter"
$verdictLabel.Location = New-Object System.Drawing.Point(10, 12)
$verdictLabel.Size = New-Object System.Drawing.Size(388, 68)
$verdictLabel.Anchor = "Top,Left,Right"
$resultPanel.Controls.Add($verdictLabel)

$metricsBox = New-Object System.Windows.Forms.ListView
$metricsBox.Location = New-Object System.Drawing.Point(10, 96)
$metricsBox.Size = New-Object System.Drawing.Size(388, 344)
$metricsBox.Anchor = "Top,Bottom,Left,Right"
$metricsBox.View = "Details"
$metricsBox.FullRowSelect = $true
[void]$metricsBox.Columns.Add("Wert", 150)
[void]$metricsBox.Columns.Add("Ergebnis", 220)
$resultPanel.Controls.Add($metricsBox)

$warningBox = New-Object System.Windows.Forms.TextBox
$warningBox.Multiline = $true
$warningBox.ReadOnly = $true
$warningBox.ScrollBars = "Vertical"
$warningBox.Location = New-Object System.Drawing.Point(10, 456)
$warningBox.Size = New-Object System.Drawing.Size(388, 88)
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

$infoPanel = New-Object System.Windows.Forms.TableLayoutPanel
$infoPanel.Dock = "Fill"
$infoPanel.Padding = New-Object System.Windows.Forms.Padding(18)
$infoPanel.ColumnCount = 1
$infoPanel.RowCount = 5
$infoPanel.AutoScroll = $true
$infoPanel.BackColor = [System.Drawing.Color]::White
$infoPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
foreach ($height in @(88, 110, 132, 112, 76)) {
    $infoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $height))) | Out-Null
}

function New-InfoBox {
    param(
        [string]$Title,
        [string]$Body,
        [System.Drawing.Color]$Accent
    )
    $box = New-Object System.Windows.Forms.Panel
    $box.Dock = "Fill"
    $box.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $box.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = "Left"
    $bar.Width = 5
    $bar.BackColor = $Accent
    $box.Controls.Add($bar)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 44, 57)
    $titleLabel.Location = New-Object System.Drawing.Point(18, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(980, 24)
    $titleLabel.Anchor = "Top,Left,Right"
    $box.Controls.Add($titleLabel)

    $bodyLabel = New-Object System.Windows.Forms.Label
    $bodyLabel.Text = $Body
    $bodyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $bodyLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 43, 52)
    $bodyLabel.Location = New-Object System.Drawing.Point(18, 40)
    $bodyLabel.Size = New-Object System.Drawing.Size(980, 60)
    $bodyLabel.Anchor = "Top,Left,Right"
    $bodyLabel.AutoSize = $false
    $box.Controls.Add($bodyLabel)
    return $box
}

$infoPanel.Controls.Add((New-InfoBox "Easy SSD Tester" "$script:AppVersion`r`n$script:CopyrightLine`r`n$script:LicenseLine" ([System.Drawing.Color]::FromArgb(52, 152, 219))), 0, 0)
$infoPanel.Controls.Add((New-InfoBox "Zweck" "Portable Freeware fuer Windows 11. Prueft SSDs und Laufwerke mit Windows-Daten und optional mit smartctl.exe, ohne lokale Installation." ([System.Drawing.Color]::FromArgb(46, 204, 113))), 0, 1)
$infoPanel.Controls.Add((New-InfoBox "SMART und NVMe" "Fuer vollstaendige SMART-/NVMe-Werte smartctl.exe in Tools\smartctl.exe ablegen oder in PATH bereitstellen. Bei USB-Adaptern muss SMART-Passthrough unterstuetzt werden." ([System.Drawing.Color]::FromArgb(155, 89, 182))), 0, 2)
$infoPanel.Controls.Add((New-InfoBox "Grenzen" "RAID-/Intel-RST-Konfigurationen koennen SMART-Daten blockieren. Der Speed-Test ist eine Plausibilitaetsmessung, kein vollstaendiger Benchmark. Ergebnisse sind technische Einschaetzungen und keine Garantie gegen Laufwerksausfall." ([System.Drawing.Color]::FromArgb(230, 126, 34))), 0, 3)
$infoPanel.Controls.Add((New-InfoBox "Lizenz" "Easy SSD Tester wird als Public GNU / GNU GPL v3 bereitgestellt." ([System.Drawing.Color]::FromArgb(44, 62, 80))), 0, 4)
$tabInfo.Controls.Add($infoPanel)

function Refresh-Grid {
    $statusLabel.Text = "Laufwerke werden gelesen..."
    [System.Windows.Forms.Application]::DoEvents()
    $drives = Get-DriveInventory
    $script:DriveInventory = @($drives)
    $driveGrid.Rows.Clear()
    for ($i = 0; $i -lt $script:DriveInventory.Count; $i++) {
        $d = $script:DriveInventory[$i]
        $rowIndex = $driveGrid.Rows.Add(
            $d.Index,
            $d.Model,
            $d.SizeGB,
            $d.MediaType,
            $d.BusType,
            $d.Letters,
            $d.HealthStatus
        )
        $driveGrid.Rows[$rowIndex].Tag = $i
    }
    if ($driveGrid.Rows.Count -gt 0) {
        $driveGrid.ClearSelection()
        $driveGrid.Rows[0].Selected = $true
        $driveGrid.CurrentCell = $driveGrid.Rows[0].Cells[1]
    }
    if ($drives.Count -gt 0) {
        $statusLabel.Text = "$($drives.Count) Laufwerk(e) gefunden. Bitte Zeile markieren und dann Pruefen klicken."
    } elseif ($script:LastInventoryError) {
        $statusLabel.Text = "Keine Laufwerke gefunden. $script:LastInventoryError"
        [System.Windows.Forms.MessageBox]::Show("Keine Laufwerke gefunden.`r`n`r`n$script:LastInventoryError`r`n`r`nBitte als Administrator starten und pruefen, ob Windows Storage/CIM verfuegbar ist.", $script:AppName, "OK", "Warning") | Out-Null
    } else {
        $statusLabel.Text = "Keine Laufwerke gefunden."
    }
}

function Get-SelectedDrive {
    $row = $null
    if ($driveGrid.SelectedRows.Count -gt 0) {
        $row = $driveGrid.SelectedRows[0]
    } elseif ($driveGrid.CurrentRow) {
        $row = $driveGrid.CurrentRow
    }
    if (-not $row) { return $null }
    $idx = [int]$row.Tag
    if ($idx -lt 0 -or $idx -ge $script:DriveInventory.Count) { return $null }
    return $script:DriveInventory[$idx]
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

$driveGrid.Add_CellDoubleClick({
    if ($_.RowIndex -ge 0) {
        $btnAnalyze.PerformClick()
    }
})

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
