<# : batch part
@echo off
setlocal
set "SELF=%~f0"
set "SELF_ARG=%~1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:SELF))"
exit /b
#>

# =============================================================================
#  optimize-windows.bat - настройка Windows 11 одним запуском
#
#  Повторяет переключатели, которые включены в Optimizer 16.7
#  (github.com/hellzerg/optimizer) на вкладках "Универсальное" и "Windows 11",
#  и дополнительно:
#    - убирает погоду с панели задач;
#    - убирает окно UAC "Разрешить этому приложению вносить изменения?";
#    - удаляет браузер Microsoft Edge и Bing.
#
#  Запуск: двойной клик. Права администратора скрипт запросит сам (окно UAC
#  будет только при самом первом запуске - потом оно отключено).
#
#  Файл одновременно и .bat, и PowerShell: блок выше читает cmd.exe, всё ниже
#  выполняет PowerShell. Сохранять в UTF-8 без BOM, переводы строк CRLF.
#
#  Чтобы пропустить пункт - поставьте # в начале его строки в разделе
#  "ЧТО ВЫПОЛНЯТЬ" в конце файла.
# =============================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# --- Права администратора ----------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($env:SELF_ARG -eq 'elevated') {
        Write-Host 'Не удалось получить права администратора.' -ForegroundColor Red
        Read-Host 'Нажмите Enter для выхода' | Out-Null
    } else {
        try   { Start-Process -FilePath $env:SELF -ArgumentList 'elevated' -Verb RunAs -ErrorAction Stop }
        catch { Write-Host 'Скрипту нужны права администратора - запуск отменён.' -ForegroundColor Red; Start-Sleep -Seconds 3 }
    }
    exit
}

$Host.UI.RawUI.WindowTitle = 'Настройка Windows'
try { Start-Transcript -Path ([IO.Path]::ChangeExtension($env:SELF, '.log')) -Force | Out-Null } catch { }

# =============================================================================
#  Вспомогательные функции
# =============================================================================

$Failed = New-Object 'System.Collections.Generic.List[string]'
$Hives  = @{ HKLM = 'HKEY_LOCAL_MACHINE'; HKCU = 'HKEY_CURRENT_USER'; HKCR = 'HKEY_CLASSES_ROOT'; HKU = 'HKEY_USERS' }
$StepNo = @{ N = 0 }

# Записать значение в реестр (ключ создаётся, если его нет). Тип: DWord | String | ExpandString.
# Пустое имя '' - значение "(По умолчанию)".
function Set-Reg {
    param([string]$Key, [string]$Name, $Value, [string]$Type = 'DWord', [switch]$Quiet)
    $hive, $path = $Key -split '\\', 2
    $err = $null
    try {
        $data = if ($Type -eq 'DWord') { [int]$Value } else { [string]$Value }
        [Microsoft.Win32.Registry]::SetValue("$($Hives[$hive])\$path", $Name, $data, [Microsoft.Win32.RegistryValueKind]$Type)
        return
    } catch {
        $err = $_.Exception.Message
    }
    # Запасной путь: иногда .NET не может записать значение, а reg.exe (с полными правами) - может
    $regType = @{ DWord = 'REG_DWORD'; String = 'REG_SZ'; ExpandString = 'REG_EXPAND_SZ' }[$Type]
    $regData = if ($Type -eq 'DWord') { [string][int]$Value } else { [string]$Value }
    $nameArg = if ([string]::IsNullOrEmpty($Name)) { @('/ve') } else { @('/v', $Name) }
    $null = & reg.exe add $Key @nameArg /t $regType /d $regData /f 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
        $label = if ([string]::IsNullOrEmpty($Name)) { '(default)' } else { $Name }
        $Failed.Add("$Key -> $label [$err]")
    }
}

# Остановить службу и отключить её запуск. Службы, которых нет в этой версии Windows, пропускаются.
function Disable-Svc {
    param([string[]]$Name)
    foreach ($svc in $Name) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (-not (Test-Path -LiteralPath $key)) { continue }
        Stop-Service -Name $svc -Force -NoWait -ErrorAction SilentlyContinue
        try {
            Set-ItemProperty -LiteralPath $key -Name 'Start' -Value 4 -Type DWord -ErrorAction Stop
        } catch {
            # защищённая служба - меняем через диспетчер служб
            sc.exe config $svc start= disabled | Out-Null
            if ($LASTEXITCODE -ne 0) { $Failed.Add("служба $svc") }
        }
    }
}

# Отключить задачу планировщика. Список всех задач читается один раз и кэшируется;
# задачи, которых нет в системе, просто пропускаются - без ошибок в консоли.
$script:TaskCache = $null
function Disable-Task([string]$Task) {
    if ($null -eq $script:TaskCache) {
        $script:TaskCache = @{}
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $script:TaskCache["$($t.TaskPath)$($t.TaskName)"] = $t
        }
    }
    if ($Task[0] -ne '\') { $Task = "\$Task" }   # задачи в корне (например, NVIDIA) идут без пути
    $t = $script:TaskCache[$Task]
    if ($t -and $t.State -ne 'Disabled') {
        try { $t | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

# Не давать программе запускаться (Image File Execution Options -> Debugger), как в Optimizer
function Block-Process([string]$Exe) {
    Set-Reg "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$Exe" 'Debugger' '%windir%\System32\taskkill.exe' String
}

# Удалить приложения Microsoft Store у всех пользователей и из образа для новых пользователей
function Remove-Apps([string[]]$Names) {
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    foreach ($name in $Names) {
        foreach ($pkg in @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)) {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
        foreach ($p in @($provisioned | Where-Object { $_.DisplayName -eq $name })) {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
        if (Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue) { $Failed.Add("приложение $name") }
    }
}

function Step([string]$Title, [string]$Action) {
    $StepNo.N++
    Write-Host ('[{0,2}] {1}' -f $StepNo.N, $Title) -ForegroundColor Cyan
    try { & $Action } catch { $Failed.Add("$Title : $($_.Exception.Message)") }
}

# =============================================================================
#  Optimizer -> "Универсальное" -> Система
# =============================================================================

# Оптимизация производительности
function EnablePerformanceTweaks {
    # автодополнение в окне "Выполнить"
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete' 'Append Completion' 'yes' String
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete' 'AutoSuggest' 'yes' String
    # маленький дамп памяти при сбое
    Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled' 3
    # отключить удалённого помощника
    Set-Reg 'HKLM\System\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0
    # отключить сворачивание окон встряхиванием
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DisallowShaking' 1
    # "Копировать в папку..." / "Переместить в папку..." в контекстном меню
    Set-Reg 'HKCR\AllFilesystemObjects\shellex\ContextMenuHandlers\Copy To' '' '{C2FBB630-2971-11D1-A18C-00C04FD75D13}' String
    Set-Reg 'HKCR\AllFilesystemObjects\shellex\ContextMenuHandlers\Move To' '' '{C2FBB631-2971-11D1-A18C-00C04FD75D13}' String
    # быстрее закрывать зависшие программы при выключении
    Set-Reg 'HKCU\Control Panel\Desktop' 'AutoEndTasks' '1' String
    Set-Reg 'HKCU\Control Panel\Desktop' 'HungAppTimeout' '1000' String
    Set-Reg 'HKCU\Control Panel\Desktop' 'WaitToKillAppTimeout' '2000' String
    Set-Reg 'HKCU\Control Panel\Desktop' 'LowLevelHooksTimeout' '1000' String
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoLowDiskSpaceChecks' 1
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'LinkResolveIgnoreLinkInfo' 1
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoResolveSearch' 1
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoResolveTrack' 1
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoInternetOpenWith' 1
    Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '2000' String
    Disable-Svc 'DiagTrack', 'diagsvc', 'diagnosticshub.standardcollector.service', 'dmwappushservice', 'RemoteRegistry'
    # показывать расширения файлов и скрытые файлы
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1
    # приоритеты мультимедиа и игр
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NoLazyMode' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'AlwaysOn' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority' 8
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority' 6
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'High' String
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority' 'High' String
    Set-Reg 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows Media Foundation' 'EnableFrameServerMode' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Low Latency' 'GPU Priority' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Low Latency' 'Priority' 8
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Low Latency' 'Scheduling Category' 'Medium' String
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Low Latency' 'SFIO Priority' 'High' String
}

# Убрать задержку меню
function RemoveMenusDelay {
    Set-Reg 'HKCU\Control Panel\Desktop' 'MenuShowDelay' '0' String
    Set-Reg 'HKCU\Control Panel\Mouse' 'MouseHoverTime' '0' String
}

# Оптимизация сети, троттлинга
function DisableNetworkThrottling {
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 0xFFFFFFFF
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0
}

# Отключить отчеты об ошибках
function DisableErrorReporting {
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\PCHealth\ErrorReporting' 'DoReport' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Disable-Svc 'WerSvc', 'wercplsupport'
}

# Отключить службу факса
function DisableFaxService {
    Disable-Svc 'Fax'
}

# Отключить залипание клавиш (и фильтрацию / озвучивание переключения)
function DisableStickyKeys {
    foreach ($root in 'HKCU', 'HKU\.DEFAULT') {
        Set-Reg "$root\Control Panel\Accessibility\StickyKeys" 'Flags' '506' String
        Set-Reg "$root\Control Panel\Accessibility\Keyboard Response" 'Flags' '122' String
        Set-Reg "$root\Control Panel\Accessibility\ToggleKeys" 'Flags' '58' String
    }
}

# Отключить SmartScreen
function DisableSmartScreen {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1
    Set-Reg 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'ScanWithAntiVirus' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'ShellSmartScreenLevel' 'Warn' String
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' String
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Internet Explorer\PhishingFilter' 'EnabledV9' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\AppHost' 'PreventOverride' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance' 'Enabled' 0
}

# =============================================================================
#  Optimizer -> "Универсальное" -> Приложения
# =============================================================================

# Отключить телеметрию Office
function DisableOffice2016Telemetry {
    foreach ($t in 'OfficeTelemetryAgentFallBack2016', 'OfficeTelemetryAgentLogOn2016', 'OfficeTelemetryAgentFallBack', 'OfficeTelemetryAgentLogOn') {
        Disable-Task "\Microsoft\Office\$t"
    }
    foreach ($v in '15.0', '16.0') {
        Set-Reg "HKCU\SOFTWARE\Microsoft\Office\$v\Outlook\Options\Mail" 'EnableLogging' 0
        Set-Reg "HKCU\SOFTWARE\Microsoft\Office\$v\Outlook\Options\Calendar" 'EnableCalendarLogging' 0
        Set-Reg "HKCU\SOFTWARE\Microsoft\Office\$v\Word\Options" 'EnableLogging' 0
        Set-Reg "HKCU\SOFTWARE\Policies\Microsoft\Office\$v\OSM" 'EnableLogging' 0
        Set-Reg "HKCU\SOFTWARE\Policies\Microsoft\Office\$v\OSM" 'EnableUpload' 0
        Set-Reg "HKCU\SOFTWARE\Microsoft\Office\$v\Common" 'QMEnable' 0
        Set-Reg "HKCU\SOFTWARE\Microsoft\Office\$v\Common\Feedback" 'Enabled' 0
    }
    foreach ($k in 'HKCU\SOFTWARE\Microsoft\Office\Common\ClientTelemetry', 'HKCU\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry') {
        Set-Reg $k 'DisableTelemetry' 1
        Set-Reg $k 'VerboseLogging' 0
    }
    foreach ($n in 'accesssolution', 'olksolution', 'onenotesolution', 'pptsolution', 'projectsolution', 'publishersolution', 'visiosolution', 'wdsolution', 'xlsolution') {
        Set-Reg 'HKCU\Software\Policies\Microsoft\Office\16.0\OSM\PreventedApplications' $n 1
    }
    foreach ($n in 'agave', 'appaddins', 'comaddins', 'documentfiles', 'templatefiles') {
        Set-Reg 'HKCU\Software\Policies\Microsoft\Office\16.0\OSM\PreventedSolutionTypes' $n 1
    }
}

# Отключить телеметрию Mozilla Firefox
function DisableFirefoxTelemetry {
    Set-Reg 'HKLM\SOFTWARE\Policies\Mozilla\Firefox' 'DisableTelemetry' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Mozilla\Firefox' 'DisableDefaultBrowserAgent' 1
    Disable-Task '\Mozilla\Firefox Default Browser Agent 308046B0AF4A39CB'
    Disable-Task '\Mozilla\Firefox Default Browser Agent D2CEEC440E2074BD'
}

# Отключить телеметрию Google Chrome
function DisableChromeTelemetry {
    Block-Process 'software_reporter_tool.exe'
    Set-Reg 'HKLM\SOFTWARE\Policies\Google\Chrome' 'MetricsReportingEnabled' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Google\Chrome' 'ChromeCleanupReportingEnabled' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Google\Chrome' 'ChromeCleanupEnabled' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Google\Chrome' 'UserFeedbackAllowed' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Google\Chrome' 'DeviceMetricsReportingEnabled' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Google\Chrome' 'ExtensionManifestV2Availability' 2
}

# Отключить телеметрию NVIDIA
function DisableNvidiaTelemetry {
    Disable-Svc 'NvTelemetryContainer'
    foreach ($t in 'NvTmRepOnLogon', 'NvTmRep', 'NvTmMon') {
        Disable-Task "${t}_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}"
    }
}

# Отключить телеметрию Visual Studio
function DisableVisualStudioTelemetry {
    Set-Reg 'HKCU\Software\Microsoft\VisualStudio\Telemetry' 'TurnOffSwitch' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableFeedbackDialog' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableEmailInput' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableScreenshotCapture' 1
    Set-Reg 'HKLM\Software\Policies\Microsoft\VisualStudio\SQM' 'OptIn' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\Setup' 'ConcurrentDownloads' 2
    foreach ($v in '14.0', '15.0', '16.0') {
        Set-Reg "HKLM\SOFTWARE\Microsoft\VSCommon\$v\SQM" 'OptIn' 0
    }
    Disable-Svc 'VSStandardCollectorService150'
}

# =============================================================================
#  Optimizer -> "Универсальное" -> Конфиденциальность
# =============================================================================

# Отключить телеметрию (задачи планировщика)
function DisableTelemetryTasks {
    # Optimizer здесь ещё пытается запретить SYSTEM доступ к папке Diagnosis\ETLLogs\AutoLogger,
    # но из-за ошибки в его коде эта команда никогда не срабатывает - поэтому её здесь нет.
    Block-Process 'CompatTelRunner.exe'
    Block-Process 'DeviceCensus.exe'
    $tasks = @(
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\BthSQM',
        '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\Customer Experience Improvement Program\Uploader',
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Application Experience\AitAgent',
        '\Microsoft\Windows\Application Experience\PcaPatchDbTask',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver',
        '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem',
        '\Microsoft\Windows\Shell\FamilySafetyMonitor',
        '\Microsoft\Windows\Shell\FamilySafetyRefresh',
        '\Microsoft\Windows\Shell\FamilySafetyUpload',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Maintenance\WinSAT',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        '\Microsoft\Windows\CloudExperienceHost\CreateObjectTask',
        '\Microsoft\Windows\DiskFootprint\Diagnostics',
        '\Microsoft\Windows\FileHistory\File History (maintenance mode)',
        '\Microsoft\Windows\PI\Sqm-Tasks',
        '\Microsoft\Windows\NetTrace\GatherNetworkInfo',
        '\Microsoft\Windows\AppID\SmartScreenSpecific',
        '\Microsoft\Windows\WindowsUpdate\Automatic App Update',
        # Эти две задачи синхронизируют часы через интернет. Optimizer их отключает,
        # поэтому они здесь есть; если часы начнут уходить - удалите эти две строки.
        '\Microsoft\Windows\Time Synchronization\ForceSynchronizeTime',
        '\Microsoft\Windows\Time Synchronization\SynchronizeTime',
        '\Microsoft\Windows\HelloFace\FODCleanupTask',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Device Information\Device',
        '\Microsoft\Windows\Device Information\Device User'
    )
    foreach ($t in $tasks) { Disable-Task $t }
}

# Отключить общий доступ к медиаплееру
function DisableMediaPlayerSharing {
    Disable-Svc 'WMPNetworkSvc'
}

# Отключить обмен файлами через домашнюю группу
function DisableHomeGroup {
    Disable-Svc 'HomeGroupListener', 'HomeGroupProvider'
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\HomeGroup' 'DisableHomeGroup' 1
}

# Отключить протокол SMBv1 / SMBv2 (серверная часть: этот ПК перестаёт раздавать папки по сети)
function DisableSMBv1 { Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1' 0 }
function DisableSMBv2 { Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB2' 0 }

# =============================================================================
#  Optimizer -> "Windows 11" -> Система
# =============================================================================

# Вернуть классический проводник: открывать "Этот компьютер", без частых папок/недавних файлов
function DisableQuickAccessHistory {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager' 'EnthusiastMode' 1
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
}

# Выключить отображение контактов
function DisableMyPeople {
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People' 'PeopleBand' 0
}

# Выключить ограничение в 260 символов в пути к файлу
function EnableLongPaths {
    Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1
}

# Выключить обмен контентом Miracast ("Передать на устройство" в контекстном меню)
function RemoveCastToDevice {
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' '{7AD84985-87B4-4a16-BE58-8B72A5B390F7}' 'Play to Menu' String
}

# Восстановить классический просмотрщик фотографий
function RestoreClassicPhotoViewer {
    $cmd = '%SystemRoot%\System32\rundll32.exe "%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll", ImageView_Fullscreen %1'
    Set-Reg 'HKCR\Applications\photoviewer.dll\shell\open' 'MuiVerb' '@photoviewer.dll,-3043' String
    Set-Reg 'HKCR\Applications\photoviewer.dll\shell\open\command' '' $cmd ExpandString
    Set-Reg 'HKCR\Applications\photoviewer.dll\shell\open\DropTarget' 'Clsid' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Bitmap' 'ImageOptionFlags' 0x00000001
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Bitmap' 'FriendlyTypeName' '@%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll,-3056' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Bitmap\DefaultIcon' '' '%SystemRoot%\System32\imageres.dll,-70' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Bitmap\shell\open\command' '' $cmd ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Bitmap\shell\open\DropTarget' 'Clsid' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' String
    Set-Reg 'HKCR\Applications\photoviewer.dll\shell\print' 'NeverDefault' '' String
    Set-Reg 'HKCR\Applications\photoviewer.dll\shell\print\command' '' $cmd ExpandString
    Set-Reg 'HKCR\Applications\photoviewer.dll\shell\print\DropTarget' 'Clsid' '{60fd46de-f830-4894-a628-6fa81bc0190d}' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.JFIF' 'EditFlags' 0x00010000
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.JFIF' 'ImageOptionFlags' 0x00000001
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.JFIF' 'FriendlyTypeName' '@%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll,-3055' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.JFIF\DefaultIcon' '' '%SystemRoot%\System32\imageres.dll,-72' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.JFIF\shell\open' 'MuiVerb' '@%ProgramFiles%\Windows Photo Viewer\photoviewer.dll,-3043' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.JFIF\shell\open\command' '' $cmd ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.JFIF\shell\open\DropTarget' 'Clsid' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Jpeg' 'EditFlags' 0x00010000
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Jpeg' 'ImageOptionFlags' 0x00000001
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Jpeg' 'FriendlyTypeName' '@%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll,-3055' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Jpeg\DefaultIcon' '' '%SystemRoot%\System32\imageres.dll,-72' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Jpeg\shell\open' 'MuiVerb' '@%ProgramFiles%\Windows Photo Viewer\photoviewer.dll,-3043' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Jpeg\shell\open\command' '' $cmd ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Jpeg\shell\open\DropTarget' 'Clsid' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Gif' 'ImageOptionFlags' 0x00000001
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Gif' 'FriendlyTypeName' '@%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll,-3057' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Gif\DefaultIcon' '' '%SystemRoot%\System32\imageres.dll,-83' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Gif\shell\open\command' '' $cmd ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Gif\shell\open\DropTarget' 'Clsid' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Png' 'ImageOptionFlags' 0x00000001
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Png' 'FriendlyTypeName' '@%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll,-3057' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Png\DefaultIcon' '' '%SystemRoot%\System32\imageres.dll,-71' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Png\shell\open\command' '' $cmd ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Png\shell\open\DropTarget' 'Clsid' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Wdp' 'EditFlags' 0x00010000
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Wdp' 'ImageOptionFlags' 0x00000001
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Wdp\DefaultIcon' '' '%SystemRoot%\System32\wmphoto.dll,-400' String
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Wdp\shell\open' 'MuiVerb' '@%ProgramFiles%\Windows Photo Viewer\photoviewer.dll,-3043' ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Wdp\shell\open\command' '' $cmd ExpandString
    Set-Reg 'HKCR\PhotoViewer.FileAssoc.Wdp\shell\open\DropTarget' 'Clsid' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' String
    Set-Reg 'HKCR\SystemFileAssociations\image\shell\Image Preview\command' '' $cmd ExpandString
    Set-Reg 'HKCR\SystemFileAssociations\image\shell\Image Preview\DropTarget' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' '' String
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities' 'ApplicationDescription' '@%ProgramFiles%\Windows Photo Viewer\photoviewer.dll,-3069' String
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities' 'ApplicationName' '@%ProgramFiles%\Windows Photo Viewer\photoviewer.dll,-3009' String
    $assoc = @{
        '.bmp' = 'Bitmap'; '.dib' = 'Bitmap'; '.gif' = 'Gif'; '.png' = 'Png'
        '.jpg' = 'Jpeg'; '.jpe' = 'Jpeg'; '.jpeg' = 'Jpeg'; '.jfif' = 'JFIF'
        '.wdp' = 'Wdp'; '.jxr' = 'Wdp'; '.tif' = 'Tiff'; '.tiff' = 'Tiff'; '.cr2' = 'Tiff'
    }
    foreach ($ext in $assoc.Keys) {
        Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' $ext "PhotoViewer.FileAssoc.$($assoc[$ext])" String
    }
}

# =============================================================================
#  Optimizer -> "Windows 11" -> Windows Update / Панель задач
# =============================================================================

# Выключить Insider Service
function DisableInsiderService {
    Disable-Svc 'wisvc'
}

# Выровнять панель задач по левому краю
function AlignTaskbarToLeft {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0
}

# =============================================================================
#  Optimizer -> "Windows 11" -> Конфиденциальность
# =============================================================================

# Выключить телеметрию (службы)
function DisableTelemetryServices {
    Disable-Svc 'DiagTrack', 'diagnosticshub.standardcollector.service', 'dmwappushservice', 'DcpSvc'
    Set-Reg 'HKLM\Software\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots' 'value' 0
    Set-Reg 'HKLM\Software\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting' 'value' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableEngine' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'SbEnable' 0
    Set-Reg 'HKLM\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\AppCompat' 'DisableEngine' 1
    Set-Reg 'HKLM\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\AppCompat' 'SbEnable' 0
    Set-Reg 'HKLM\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableUAR' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
    Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\WMI\AutoLogger\SQMLogger' 'Start' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\System' 'AllowExperimentation' 0
    Disable-Svc 'WdiServiceHost'
}

# Выключить Cortana (и веб-поиск Bing в меню "Пуск")
function DisableCortana {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWebOverMeteredConnections' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'HistoryViewEnabled' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'DeviceHistoryEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'AllowSearchToUseLocation' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCloudSearch' 0
}

# Улучшение конфиденциальности
function EnhancePrivacy {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'DisableWindowsSpotlightFeatures' 1
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'DisableTailoredExperiencesWithDiagnosticData' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Bluetooth' 'AllowAdvertising' 0
    # Учётные записи -> Варианты входа -> Конфиденциальность
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableAutomaticRestartSignOn' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\TabletPC' 'PreventHandwritingDataSharing' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput' 'AllowLinguisticDataCollection' 0
    # Конфиденциальность -> Речь
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'SafeSearchMode' 0
    # Журнал действий
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowCrossDeviceClipboard' 0
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\Messaging' 'AllowMessageSync' 0
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\SettingSync' 'DisableCredentialsSettingSync' 2
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\SettingSync' 'DisableCredentialsSettingSyncUserOverride' 1
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\SettingSync' 'DisableApplicationSettingSync' 2
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\SettingSync' 'DisableApplicationSettingSyncUserOverride' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsActivateWithVoice' 2
    # Поиск устройства
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Settings\FindMyDevice' 'LocationSyncEnabled' 0
    # Временная шкала и общие возможности
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableCdp' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack' 'ShowedToastAtLevel' 1
    Set-Reg 'HKU\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack' 'ShowedToastAtLevel' 1
    Set-Reg 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' String
    # Определение местоположения
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocationScripting' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableWindowsLocationProvider' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 0
    Set-Reg 'HKLM\System\CurrentControlSet\Services\lfsvc\Service\Configuration' 'Status' 0
    # Биометрия (Windows Hello: отпечаток пальца / лицо) - так делает Optimizer
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Biometrics' 'Enabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarOpenOnHover' 0
    # Обмен с другими устройствами
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\CDP' 'CdpSessionUserAuthzPolicy' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\CDP' 'NearShareChannelUserAuthzPolicy' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\CDP' 'RomeSdkChannelUserAuthzPolicy' 0
    # Онлайн-проверка KMS-клиента
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform' 'NoGenTicket' 1
    # Общие
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost\EnableWebContentEvaluation' 'Enabled' 0
    Set-Reg 'HKCU\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SmartGlass' 'UserAuthPolicy' 0
    # Речь, рукописный ввод и ввод текста
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Language' 'Enabled' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
    Set-Reg 'HKCU\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
    Set-Reg 'HKCU\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Input\TIPC' 'Enabled' 0
    # Другие устройства
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsSyncWithDevices' 2
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\LooselyCoupled' 'Value' 'Deny' String
    # Диагностика и отзывы
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'MaxTelemetryAllowed' 0
    Set-Reg 'HKCU\Software\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' 0
    Set-Reg 'HKCU\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM\SYSTEM\ControlSet001\Control\WMI\AutoLogger\AutoLogger-Diagtrack-Listener' 'Start' 0
    Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\WMI\AutoLogger\AutoLogger-Diagtrack-Listener' 'Start' 0
    # Wi-Fi Sense, Hotspot 2.0, удалённое включение мобильного хот-спота
    Set-Reg 'HKLM\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config' 'AutoConnectAllowedOEM' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\WcmSvc\Tethering' 'Hotspot2SignUp' 1
    Set-Reg 'HKLM\SOFTWARE\Microsoft\WlanSvc\AnqpCache' 'OsuRegistrationStatus' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\WcmSvc\Tethering' 'RemoteStartupDisabled' 1
    # Проецирование на этот компьютер
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Connect' 'AllowProjectionToPC' 0
    # Связь с телефоном
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\System' 'EnableMmx' 0
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\System' 'RSoPLogging' 0
}

# Выключить рекламу (в "Пуске", Проводнике, уведомлениях)
function DisableStartMenuAds {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Mobility' 'OptedIn' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    $cdm = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SubscribedContent-88000326Enabled', 'ContentDeliveryAllowed', 'PreInstalledAppsEverEnabled',
                   'SilentInstalledAppsEnabled', 'SubscribedContent-314559Enabled', 'SubscribedContent-338387Enabled',
                   'SubscribedContent-338389Enabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-338393Enabled',
                   'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled',
                   'SubscribedContent-338388Enabled', 'SubscribedContentEnabled', 'SoftLandingEnabled', 'FeatureManagementEnabled') {
        Set-Reg $cdm $n 0
    }
    Set-Reg 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'AllowOnlineTips' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
}

# Отключить телеметрию Edge (политики остаются и после удаления Edge - на случай, если Windows его вернёт)
function DisableEdgeTelemetry {
    foreach ($root in 'HKLM', 'HKCU') {
        Set-Reg "$root\SOFTWARE\Policies\Microsoft\Edge" 'PersonalizationReportingEnabled' 0
        Set-Reg "$root\SOFTWARE\Policies\Microsoft\Edge" 'UserFeedbackAllowed' 0
        Set-Reg "$root\SOFTWARE\Policies\Microsoft\Edge" 'MetricsReportingEnabled' 0
        Set-Reg "$root\SOFTWARE\Policies\Microsoft\Edge" 'SpotlightExperiencesAndRecommendationsEnabled' 0
        Set-Reg "$root\SOFTWARE\Policies\Microsoft\MicrosoftEdge\BooksLibrary" 'EnableExtendedBooksTelemetry' 0
    }
    Set-Reg 'HKCU\Software\Microsoft\Edge\SmartScreenEnabled' '' 0
    Set-Reg 'HKCU\Software\Microsoft\Edge\SmartScreenPuaEnabled' '' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ExtensionManifestV2Availability' 2
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'Edge3PSerpTelemetryEnabled' 0
}

# Отключить боковую панель / "Обнаружение" в Edge
function DisableEdgeDiscoverBar {
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0
    Set-Reg 'HKCU\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'WebWidgetAllowed' 0
}

# =============================================================================
#  Optimizer -> "Windows 11" -> Игры
# =============================================================================

# Включить игровой режим (+ аппаратное планирование GPU)
function EnableGamingMode {
    Set-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Set-Reg 'HKCU\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Set-Reg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2
}

# Выключить Xbox Live
function DisableXboxLive {
    Disable-Svc 'XboxNetApiSvc', 'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'xbgm'
    Disable-Task '\Microsoft\XblGameSave\XblGameSaveTask'
    Disable-Task '\Microsoft\XblGameSave\XblGameSaveTaskLogon'
}

# Выключить Game Bar
function DisableGameBar {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AudioCaptureEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'CursorCaptureEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\GameBar' 'ShowStartupPanel' 0
    Set-Reg 'HKCU\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKLM\Software\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
}

# =============================================================================
#  Optimizer -> "Windows 11" -> Сенсорный экран
# =============================================================================

# Выключить режим рисования / сенсорного ввода (Windows Ink)
function DisableWindowsInk {
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace' 'AllowWindowsInkWorkspace' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace' 'AllowSuggestedAppsInWindowsInkWorkspace' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\TabletTip\1.7' 'EnableInkingWithTouch' 0
}

# Выключить проверку правописания и подсказки при вводе
function DisableSpellingAndTypingFeatures {
    Set-Reg 'HKCU\SOFTWARE\Microsoft\TabletTip\1.7' 'EnableAutocorrection' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\TabletTip\1.7' 'EnableSpellchecking' 0
    Set-Reg 'HKCU\Software\Microsoft\Input\Settings' 'InsightsEnabled' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\TabletTip\1.7' 'EnableDoubleTapSpace' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\TabletTip\1.7' 'EnablePredictionSpaceInsertion' 0
    Set-Reg 'HKCU\SOFTWARE\Microsoft\TabletTip\1.7' 'EnableTextPrediction' 0
}

# Отключить облачный буфер обмена (и журнал буфера обмена Win+V)
function DisableCloudClipboard {
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowCrossDeviceClipboard' 0
    Set-Reg 'HKCU\Software\Microsoft\Clipboard' 'EnableClipboardHistory' 0
    Set-Reg 'HKLM\Software\Microsoft\Clipboard' 'EnableClipboardHistory' 0
}

# =============================================================================
#  Optimizer -> "Windows 11" -> Дополнительно
# =============================================================================

# Отключить Snap Assist
function DisableSnapAssist {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'EnableSnapAssistFlyout' 0
    Set-Reg 'HKCU\Control Panel\Desktop' 'DockMoving' '0' String
}

# Вернуть классическое контекстное меню (без "Показать дополнительные параметры")
function DisableShowMoreOptions {
    Set-Reg 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' '' String
}

# Включить компактный режим в Проводнике
function EnableFilesCompactMode {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'UseCompactMode' 1
}

# Отключить Copilot (и Recall)
function DisableCoPilotAI {
    Set-Reg 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'DefaultBrowserSettingsCampaignEnabled' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ComposeInlineEnabled' 0
    Set-Reg 'HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
}

# =============================================================================
#  Дополнительно (этого нет в Optimizer)
# =============================================================================

# Скрыть погоду на панели задач.
# В Windows 10 погода - это "Новости и интересы" (первые два значения, как в Optimizer).
# В Windows 11 погоду показывает кнопка "Виджеты": её убирает переключатель TaskbarDa
# у пользователя и машинная политика Dsh "Configure widgets". После этого нужен
# перезапуск Проводника (делается в конце скрипта).
function HideTaskbarWeather {
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds' 'IsFeedsAvailable' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
}

# Убрать окно UAC "Разрешить этому приложению вносить изменения на вашем устройстве?".
# Программы, которым нужны права администратора, получают их без вопроса. Сам UAC (EnableLUA)
# не выключается: остальные программы по-прежнему работают без прав администратора,
# и не ломаются приложения из Microsoft Store.
function DisableUacPrompt {
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 0
}

# Удалить Microsoft Edge.
# WebView2 (движок Edge внутри других программ) НЕ удаляется - без него ломаются многие приложения.
function RemoveEdge {
    $edgeGuid = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'   # Microsoft Edge (Stable) в Edge Update
    $edgeDirs = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application",
        "$env:ProgramFiles\Microsoft\Edge\Application",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application"
    )

    # Запрет повторной установки Edge через Edge Update (WebView2 обновляется как обычно)
    Set-Reg 'HKLM\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate' "Install$edgeGuid" 0

    $installers = @(foreach ($dir in $edgeDirs) { Get-ChildItem -Path "$dir\*\Installer\setup.exe" -ErrorAction SilentlyContinue })
    if ($installers.Count -eq 0) {
        Write-Host '     Edge не найден - уже удалён.' -ForegroundColor DarkGray
        return
    }

    Get-Process -Name 'msedge', 'MicrosoftEdgeUpdate' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # За пределами ЕС Microsoft не даёт удалить Edge. На время удаления снимаем запрет:
    #  - флаг AllowUninstall для установщика Edge;
    #  - убираем метки экспериментов, которые блокируют удаление;
    #  - создаём пустой файл старого Edge (установщик тогда считает, что браузер в системе есть);
    #  - временно ставим регион "Ирландия" (68). Ваш регион возвращается сразу после удаления.
    Set-Reg 'HKLM\SOFTWARE\Microsoft\EdgeUpdateDev' 'AllowUninstall' 1
    Set-Reg 'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev' 'AllowUninstall' 1
    foreach ($view in 'SOFTWARE\WOW6432Node', 'SOFTWARE') {
        Remove-ItemProperty -Path "HKLM:\$view\Microsoft\EdgeUpdate\ClientState\$edgeGuid" -Name 'experiment_control_labels' -ErrorAction SilentlyContinue
    }
    $stubDir        = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
    $stubFile       = "$stubDir\MicrosoftEdge.exe"
    $stubDirExisted = Test-Path -LiteralPath $stubDir
    $stubCreated    = $false
    if (-not (Test-Path -LiteralPath $stubFile)) {
        try { New-Item -Path $stubFile -ItemType File -Force -ErrorAction Stop | Out-Null; $stubCreated = $true } catch { }
    }
    $savedNation = @{}
    foreach ($geo in 'HKCU:\Control Panel\International\Geo', 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International\Geo') {
        $nation = (Get-ItemProperty -Path $geo -Name 'Nation' -ErrorAction SilentlyContinue).Nation
        if ($nation) {
            $savedNation[$geo] = $nation
            Set-ItemProperty -Path $geo -Name 'Nation' -Value '68' -ErrorAction SilentlyContinue
        }
    }

    try {
        foreach ($setup in $installers) {
            if (-not (Test-Path -LiteralPath $setup.FullName)) { continue }   # папку мог удалить предыдущий проход
            $a = @('--uninstall', '--msedge', '--channel=stable', '--force-uninstall', '--verbose-logging')
            if ($setup.FullName -notlike "$env:LOCALAPPDATA\*") { $a += '--system-level' }
            try { & $setup.FullName @a 2>&1 | Out-Null } catch { }
        }
    } finally {
        foreach ($geo in $savedNation.Keys) {
            Set-ItemProperty -Path $geo -Name 'Nation' -Value $savedNation[$geo] -ErrorAction SilentlyContinue
        }
        if ($stubCreated) {
            Remove-Item -LiteralPath $stubFile -Force -ErrorAction SilentlyContinue
            if (-not $stubDirExisted) { Remove-Item -LiteralPath $stubDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    if (@($edgeDirs | Where-Object { Test-Path -LiteralPath "$_\msedge.exe" }).Count -gt 0) {
        $Failed.Add('Microsoft Edge: Windows не дала удалить браузер (см. README)')
        return
    }
    Write-Host '     Edge удалён.' -ForegroundColor DarkGray

    # Ярлыки, оставшиеся от Edge
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($lnk in "$desktop\Microsoft Edge.lnk",
                     "$env:PUBLIC\Desktop\Microsoft Edge.lnk",
                     "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                     "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                     "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk",
                     "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk") {
        Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    }

    # Системная заглушка Edge в списке приложений (обычно исчезает вместе с браузером)
    $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
    $sids  = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    foreach ($pkg in @(Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue)) {
        foreach ($sid in $sids) {
            New-Item -Path "$store\EndOfLife\$sid\$($pkg.PackageFullName)" -Force -ErrorAction SilentlyContinue | Out-Null
        }
        New-Item -Path "$store\Deprovisioned\$($pkg.PackageFamilyName)" -Force -ErrorAction SilentlyContinue | Out-Null
        try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop } catch { }
    }
}

# Удалить Bing: приложения Bing и веб-поиск Bing в меню "Пуск"
function RemoveBing {
    Remove-Apps 'Microsoft.BingSearch', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingFinance',
                'Microsoft.BingSports', 'Microsoft.BingTranslator', 'Microsoft.BingFoodAndDrink',
                'Microsoft.BingHealthAndFitness', 'Microsoft.BingTravel'
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    Set-Reg 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCloudSearch' 0
    # "Главное в поиске" - картинки и подсказки Bing в поле поиска
    Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0
    Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0
}

# Перезапустить Проводник, чтобы изменения панели задач и меню применились сразу
function RestartExplorer {
    Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # Windows сама запускает Проводник заново; если этого не произошло - запускаем вручную
    for ($i = 0; $i -lt 10 -and -not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) { Start-Process 'explorer.exe' }
}

# =============================================================================
#  ЧТО ВЫПОЛНЯТЬ  (поставьте # в начале строки, чтобы пропустить пункт)
# =============================================================================

Write-Host ''
Write-Host '  Настройка Windows (по выбору в Optimizer + удаление Edge и Bing)' -ForegroundColor White
Write-Host ''

# --- "Универсальное" -> Система
Step 'Оптимизация производительности'                    EnablePerformanceTweaks
Step 'Убрать задержку меню'                              RemoveMenusDelay
Step 'Оптимизация сети, троттлинга'                      DisableNetworkThrottling
Step 'Отключить отчеты об ошибках'                       DisableErrorReporting
Step 'Отключить службу факса (Fax)'                      DisableFaxService
Step 'Отключить залипание клавиш'                        DisableStickyKeys
Step 'Отключить SmartScreen'                             DisableSmartScreen
# --- "Универсальное" -> Приложения
Step 'Отключить телеметрию Office'                       DisableOffice2016Telemetry
Step 'Отключить телеметрию Mozilla Firefox'              DisableFirefoxTelemetry
Step 'Отключить телеметрию Google Chrome'                DisableChromeTelemetry
Step 'Отключить телеметрию NVIDIA'                       DisableNvidiaTelemetry
Step 'Отключить телеметрию Visual Studio'                DisableVisualStudioTelemetry
# --- "Универсальное" -> Конфиденциальность
Step 'Отключить телеметрию'                              DisableTelemetryTasks
Step 'Отключить общий доступ к медиаплееру'              DisableMediaPlayerSharing
Step 'Отключить обмен файлами через домашнюю группу'     DisableHomeGroup
Step 'Отключить протокол SMBv1'                          DisableSMBv1
Step 'Отключить протокол SMBv2'                          DisableSMBv2
# --- "Windows 11" -> Система
Step 'Вернуть классический проводник'                    DisableQuickAccessHistory
Step 'Выключить отображение контактов в Проводнике'      DisableMyPeople
Step 'Выключить ограничение в 260 символов в пути'       EnableLongPaths
Step 'Выключить обмен контентом Miracast'                RemoveCastToDevice
Step 'Восстановить классический просмотрщик фотографий'  RestoreClassicPhotoViewer
# --- "Windows 11" -> Windows Update
Step 'Выключить Insider Service'                         DisableInsiderService
# --- "Windows 11" -> Панель задач
Step 'Выровнять панель задач по левому краю'             AlignTaskbarToLeft
# --- "Windows 11" -> Конфиденциальность
Step 'Выключить телеметрию'                              DisableTelemetryServices
Step 'Выключить Cortana'                                 DisableCortana
Step 'Улучшение конфиденциальности'                      EnhancePrivacy
Step 'Выключить рекламу в Проводнике'                    DisableStartMenuAds
Step 'Отключить телеметрию Edge'                         DisableEdgeTelemetry
Step 'Отключить обнаружение Edge'                        DisableEdgeDiscoverBar
# --- "Windows 11" -> Игры
Step 'Включить игровой режим'                            EnableGamingMode
Step 'Выключить Xbox Live'                               DisableXboxLive
Step 'Выключить Game Bar'                                DisableGameBar
# --- "Windows 11" -> Сенсорный экран
Step 'Выключить режим рисования/сенсорного ввода'        DisableWindowsInk
Step 'Выключить проверку правописания'                   DisableSpellingAndTypingFeatures
Step 'Отключить облачный буфер обмена'                   DisableCloudClipboard
# --- "Windows 11" -> Дополнительно
Step 'Отключить Snap Assist'                             DisableSnapAssist
Step 'Вернуть классическое контекстное меню'             DisableShowMoreOptions
Step 'Включить компактный режим в Проводнике'            EnableFilesCompactMode
Step 'Отключить CoPilot AI'                              DisableCoPilotAI
# --- Дополнительно (нет в Optimizer)
Step 'Скрыть погоду на панели задач'                     HideTaskbarWeather
Step 'Убрать запрос прав администратора (UAC)'           DisableUacPrompt
Step 'Удалить Microsoft Edge'                            RemoveEdge
Step 'Удалить Bing'                                      RemoveBing
Step 'Перезапуск Проводника'                             RestartExplorer

# =============================================================================
#  Итог
# =============================================================================

Write-Host ''
if ($Failed.Count -eq 0) {
    Write-Host 'Готово! Все настройки применены.' -ForegroundColor Green
} else {
    Write-Host "Готово. Не удалось применить ($($Failed.Count)):" -ForegroundColor Yellow
    foreach ($f in $Failed) { Write-Host "  - $f" -ForegroundColor Yellow }
    Write-Host 'Обычно это значения, которые Windows защищает от изменения. Остальное применено.' -ForegroundColor DarkGray
}
Write-Host "Журнал: $([IO.Path]::ChangeExtension($env:SELF, '.log'))" -ForegroundColor DarkGray
Write-Host ''
$answer = Read-Host 'Часть настроек заработает только после перезагрузки. Перезагрузить сейчас? (Y/N)'
try { Stop-Transcript | Out-Null } catch { }
if ($answer -match '^\s*[yYдД]') { Restart-Computer -Force }
