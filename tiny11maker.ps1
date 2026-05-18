<#
.SYNOPSIS
    Scripts to build a trimmed-down Windows 11 image.

.DESCRIPTION
    This is a script created to automate the build of a streamlined Windows 11 image.
    Only Microsoft utilities (DISM) are used. Oscdimg.exe from ADK is used for ISO creation.

.PARAMETER ISO
    Drive letter given to the mounted iso (eg: E)

.PARAMETER SCRATCH
    Drive letter of the desired scratch disk (eg: D)
#>

#---------[ Parameters ]---------#

param (
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH
)

if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $SCRATCH + ":"
}

#---------[ Functions ]---------#

function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    try {
        if ([string]::IsNullOrEmpty($name)) {
            & 'reg' 'add' $path '/ve' '/t' $type '/d' $value '/f' | Out-Null
        } else {
            & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' | Out-Null
        }
        Write-Output "Set registry value: $path\$name"
    } catch {
        Write-Output "Error setting registry value: $_"
    }
}

function Remove-RegistryKey {
    param (
        [string]$path
    )
    try {
        & 'reg' 'delete' $path '/f' | Out-Null
        Write-Output "Removed registry key: $path"
    } catch {
        Write-Output "Error removing registry key: $_"
    }
}

function Unload-OfflineRegistry {
    param([string]$path)
    $tries = 0
    while ($tries -lt 5) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $result = & 'reg' 'unload' $path 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Successfully unloaded $path"
            return $true
        }
        Start-Sleep -Seconds 2
        $tries++
    }
    Write-Error "FAILED to unload registry hive $path. It may be locked. Aborting save to prevent image corruption!"
    return $false
}

#---------[ Execution ]---------#

if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Output "Your current PowerShell Execution Policy is set to Restricted. Change to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
    } else {
        exit
    }
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Output "Restarting as admin in a new window..."
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell";
    
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($myInvocation.MyCommand.Definition)`""
    if (-not [string]::IsNullOrEmpty($ISO)) { $arguments += " -ISO `"$ISO`"" }
    if (-not [string]::IsNullOrEmpty($SCRATCH)) { $arguments += " -SCRATCH `"$SCRATCH`"" }
    
    $newProcess.Arguments = $arguments;
    $newProcess.Verb = "runas";
    [System.Diagnostics.Process]::Start($newProcess);
    exit
}

if (-not (Test-Path -Path "$PSScriptRoot/autounattend.xml")) {
    try {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml" -OutFile "$PSScriptRoot/autounattend.xml" -ErrorAction Stop
    } catch {
        Write-Warning "Failed to download autounattend.xml. Offline account bypass may not work."
    }
}

Start-Transcript -Path "$PSScriptRoot\tiny11_$(Get-Date -f yyyyMMdd_HHmmss).log"

$Host.UI.RawUI.WindowTitle = "Tiny11 image creator"
Clear-Host
Write-Output "Welcome to the tiny11 image creator!"

$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
New-Item -ItemType Directory -Force -Path "$ScratchDisk\tiny11" | Out-Null

do {
    if (-not $ISO) {
        $DriveLetterInput = Read-Host "Please enter the drive letter for the Windows 11 image"
    } else {
        $DriveLetterInput = $ISO
    }
    
    $DriveLetter = $DriveLetterInput.TrimEnd(':')
    
    if ($DriveLetter -match '^[c-zC-Z]$') {
        $DriveLetter = $DriveLetter + ":"
        Write-Output "Drive letter set to $DriveLetter"
    } else {
        Write-Output "Invalid drive letter. Please enter a single letter between C and Z."
        $DriveLetter = ""
    }
} while ([string]::IsNullOrEmpty($DriveLetter))

$freeSpace = (Get-PSDrive -Name $ScratchDisk[0]).Free
if ($freeSpace -lt 25GB) {
    Write-Error "Insufficient free space on $ScratchDisk (need at least 25 GB)."
    exit
}

if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -and (Test-Path "$DriveLetter\sources\install.wim") -eq $false -and (Test-Path "$DriveLetter\sources\install.esd") -eq $false) {
    Write-Output "Can't find Windows OS Installation files in the specified Drive Letter."
    exit
}

Write-Output "Copying Windows image using Robocopy..."
robocopy "$DriveLetter\" "$ScratchDisk\tiny11\" /E /NJH /NJS /NFL /NDL /NP | Out-Null
Write-Output "Copy complete!"

if ((Test-Path "$ScratchDisk\tiny11\sources\install.esd") -eq $true) {
    Write-Output "Found install.esd, converting to install.wim..."
    Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.esd
    $index = Read-Host "Please enter the image index"
    Write-Output 'Converting install.esd to install.wim. This may take a while...'
    Export-WindowsImage -SourceImagePath $ScratchDisk\tiny11\sources\install.esd -SourceIndex $index -DestinationImagePath $ScratchDisk\tiny11\sources\install.wim -Compressiontype Maximum -CheckIntegrity
    Set-ItemProperty -Path "$ScratchDisk\tiny11\sources\install.esd" -Name IsReadOnly -Value $false > $null 2>&1
    Remove-Item "$ScratchDisk\tiny11\sources\install.esd" > $null 2>&1
}

Start-Sleep -Seconds 2
Clear-Host
Write-Output "Getting image information:"

$index = 0
$ImagesIndex = (Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim).ImageIndex
while ($ImagesIndex -notcontains [int]$index) {
    Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim
    $index = Read-Host "Please enter the image index"
}
$index = [int]$index

Write-Output "Mounting Windows image. This may take a while."
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
& takeown "/F" $wimFilePath
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
try {
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {
    Write-Error "$wimFilePath not found"
}
New-Item -ItemType Directory -Force -Path "$ScratchDisk\scratchdir" > $null

try {
    Mount-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim -Index $index -Path $ScratchDisk\scratchdir -ErrorAction Stop
} catch {
    Write-Error "Failed to mount Windows image: $_"
    exit
}

$imageIntl = & dism /English /Get-Intl "/Image:$($ScratchDisk)\scratchdir"
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2,4})' }
if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Output "Default system UI language code: $languageCode"
} else {
    Write-Output "Default system UI language code not found."
}

$imageInfo = & 'dism' '/English' '/Get-WimInfo' "/wimFile:$($ScratchDisk)\tiny11\sources\install.wim" "/index:$index"
$lines = $imageInfo -split '\r?\n'
foreach ($line in $lines) {
    if ($line -match 'Architecture\s*:\s*(.*)') {
        $architecture = $Matches[1].Trim()
        if ($architecture -eq 'x64') { $architecture = 'amd64' }
        Write-Output "Architecture: $architecture"
        break
    }
}

Write-Output "Mounting complete! Performing removal of applications..."

$packages = & 'dism' '/English' "/image:$($ScratchDisk)\scratchdir" '/Get-ProvisionedAppxPackages' |
    ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }

$packagePrefixes = 'AppUp.IntelManagementandSecurityStatus',
'Clipchamp.Clipchamp', 
'DolbyLaboratories.DolbyAccess',
'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
'Microsoft.BingNews',
'Microsoft.BingSearch',
'Microsoft.BingWeather',
'Microsoft.Copilot',
'Microsoft.Windows.CrossDevice',
'Microsoft.GamingApp',
'Microsoft.Getstarted',
'Microsoft.Microsoft3DViewer',
'Microsoft.MicrosoftOfficeHub',
'Microsoft.MicrosoftSolitaireCollection',
'Microsoft.MicrosoftStickyNotes',
'Microsoft.MixedReality.Portal',
'Microsoft.Office.OneNote',
'Microsoft.OfficePushNotificationUtility',
'Microsoft.OutlookForWindows',
'Microsoft.People',
'Microsoft.PowerAutomateDesktop',
'Microsoft.SkypeApp',
'Microsoft.Todos',
'Microsoft.Wallet',
'Microsoft.Windows.DevHome',
'Microsoft.Windows.Copilot',
'Microsoft.Windows.Teams',
'microsoft.windowscommunicationsapps',
'Microsoft.WindowsFeedbackHub',
'Microsoft.WindowsMaps',
'Microsoft.WindowsSoundRecorder',
'Microsoft.Xbox.TCUI',
'Microsoft.XboxApp',
'Microsoft.XboxGameOverlay',
'Microsoft.XboxGamingOverlay',
'Microsoft.XboxIdentityProvider',
'Microsoft.XboxSpeechToTextOverlay',
'Microsoft.YourPhone',
'Microsoft.ZuneMusic',
'Microsoft.ZuneVideo',
'MicrosoftCorporationII.MicrosoftFamily',
'MicrosoftCorporationII.QuickAssist',
'MSTeams',
'MicrosoftTeams', 
'Microsoft.549981C3F5F10'

$packagesToRemove = $packages | Where-Object {
    $pkg = $_
    foreach ($prefix in $packagePrefixes) {
        if ($pkg -like "*$prefix*") { return $true }
    }
    return $false
}

foreach ($package in $packagesToRemove) {
    & 'dism' '/English' "/image:$($ScratchDisk)\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
}

Write-Output "Removing OneDrive:"
& 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" | Out-Null
& 'icacls' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" -Force | Out-Null
Write-Output "Removal complete!"

# ---------[ Removing language packs (except en-US & ru-RU) ]--------- #
Write-Output "Removing unnecessary language packs (keeping en-US and ru-RU)..."
$langPacks = & dism /English /Image:"$ScratchDisk\scratchdir" /Get-Packages |
    Where-Object { $_ -match 'Package Identity : (.*LanguagePack.*)' } |
    ForEach-Object { $matches[1] }

foreach ($lp in $langPacks) {
    if ($lp -like '*en-US*' -or $lp -like '*ru-RU*') {
        Write-Output "Keeping language packs: $lp"
    } else {
        Write-Output "Removing language packs: $lp"
        & dism /English /Image:"$ScratchDisk\scratchdir" /Remove-Package /PackageName:"$lp" | Out-Null
    }
}

# Removing the corresponding language features for unnecessary languages.
$otherLangPacks = & dism /English /Image:"$ScratchDisk\scratchdir" /Get-Packages |
    Where-Object { $_ -match 'Package Identity : (.*(LanguageFeatures|Speech|TextRecognition|Handwriting).*)' } |
    ForEach-Object { $matches[1] }

foreach ($lp in $otherLangPacks) {
    if ($lp -notmatch 'en-US' -and $lp -notmatch 'ru-RU') {
        Write-Output "Removing language feature: $lp"
        & dism /English /Image:"$ScratchDisk\scratchdir" /Remove-Package /PackageName:"$lp" | Out-Null
    }
}
Write-Output "Language pack removal complete."

Start-Sleep -Seconds 2
Clear-Host
Write-Output "Loading registry..."
reg load HKLM\zCOMPONENTS $ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS | Out-Null
reg load HKLM\zDEFAULT $ScratchDisk\scratchdir\Windows\System32\config\default | Out-Null
reg load HKLM\zNTUSER $ScratchDisk\scratchdir\Users\Default\ntuser.dat | Out-Null
reg load HKLM\zSOFTWARE $ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE | Out-Null
reg load HKLM\zSYSTEM $ScratchDisk\scratchdir\Windows\System32\config\SYSTEM | Out-Null

$currentControlSetNum = 1
try {
    $csVal = & reg query "HKLM\zSYSTEM\Select" /v Current 2>$null
    if ($csVal -match 'Current\s+REG_DWORD\s+0x(\d+)') { $currentControlSetNum = [int]"0x$($Matches[1])" }
} catch {}
$csPath = "HKLM\zSYSTEM\ControlSet$($currentControlSetNum.ToString('000'))"
Write-Output "Active Control Set path: $csPath"

Write-Output "Bypassing system requirements(on the system image):"
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue "$csPath\Setup\LabConfig" 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPath\Setup\LabConfig" 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPath\Setup\LabConfig" 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPath\Setup\LabConfig" 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPath\Setup\LabConfig" 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPath\Setup\MoSetup" 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

Write-Output "Disabling Sponsored Apps and Promoted Apps..."
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-RegistryKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
Remove-RegistryKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlight' 'REG_DWORD' '1'

Write-Output "Enabling Local Accounts on OOBE (BypassNRO):"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\tiny11\autounattend.xml" -Force | Out-Null

$oobeFolder = "$ScratchDisk\scratchdir\Windows\System32\oobe"
if (Test-Path $oobeFolder) {
    takeown /f $oobeFolder /r /d y 2>&1 | Out-Null
    icacls $oobeFolder /grant "*$($adminSID):(F)" /t 2>&1 | Out-Null
}

$bypassNROPath = "$ScratchDisk\scratchdir\Windows\System32\oobe\BypassNRO.cmd"
$bypassNROContent = @"
@echo off
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f
shutdown /r /o
"@
Set-Content -Path $bypassNROPath -Value $bypassNROContent -Force

Write-Output "Disabling BitLocker Device Encryption"
Set-RegistryValue "$csPath\Control\BitLocker" 'PreventDeviceEncryption' 'REG_DWORD' '1'
Write-Output "Disabling Chat icon:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

Write-Output "Disabling OneDrive folder backup"
Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"

Write-Output "Disabling Telemetry:"
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
Set-RegistryValue "$csPath\Services\dmwappushservice" 'Start' 'REG_DWORD' '4'

Write-Output "Prevents installation of DevHome and Outlook:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
Remove-RegistryKey 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
Remove-RegistryKey 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

Write-Output "Disabling Copilot"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

Write-Output "Prevents installation of Teams:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

Write-Output "Prevent installation of New Outlook:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

Write-Output "Deleting scheduled task definition files..."
$tasksPath = "$ScratchDisk\scratchdir\Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Write-Output "Task files have been deleted."

# ---------[ CUSTOM TWEAKS ]--------- #
Write-Output "Applying custom tweaks..."

Write-Output "1. Enabling Classic Context Menu..."
Set-RegistryValue 'HKLM\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' 'REG_SZ' ''
Set-RegistryValue 'HKLM\zDEFAULT\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' 'REG_SZ' ''

Write-Output "2. Disabling Widgets..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'REG_DWORD' '0'

Write-Output "3. Disabling Context Menu delay (set to 10 ms)..."
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\Desktop' 'MenuShowDelay' 'REG_SZ' '10'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'MenuShowDelay' 'REG_SZ' '10'

Write-Output "4. Enabling AutoEndTasks on shutdown..."
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\Desktop' 'AutoEndTasks' 'REG_SZ' '1'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'AutoEndTasks' 'REG_SZ' '1'

Write-Output "5. Disabling Sticky Keys shortcut..."
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\Accessibility\StickyKeys' 'Flags' 'REG_SZ' '506'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Accessibility\StickyKeys' 'Flags' 'REG_SZ' '506'

Write-Output "6. Aligning Taskbar to the left..."
Set-RegistryValue 'HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 'REG_DWORD' '0'

Write-Output "7. Disabling auto-reboot with logged on users..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 'REG_DWORD' '1'

Write-Output "8. Disabling Hibernation (via registry)..."
Set-RegistryValue "$csPath\Control\Power" 'HibernateEnabled' 'REG_DWORD' '0'

Write-Output "9. Applying SSD optimizations..."
Set-RegistryValue "$csPath\Control\FileSystem" 'NtfsDisableLastAccessUpdate' 'REG_DWORD' '1'
Set-RegistryValue "$csPath\Control\FileSystem" 'NtfsDisable8dot3NameCreation' 'REG_DWORD' '1'

Write-Output "10. Disabling Bing Search..."
Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

Write-Output "11. Enabling Verbose Shutdown/Startup status messages..."
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'verbosestatus' 'REG_DWORD' '1'

Write-Output "12. Disabling Settings suggestions and tips..."
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-807589Enabled' 'REG_DWORD' '0'

Write-Output "13. Disabling Activity History..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 'REG_DWORD' '0'

Write-Output "14. Disabling 'Use this app for all' Store prompt..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'NoUseStoreOpenWith' 'REG_DWORD' '1'

Write-Output "15. Disabling Windows Experimentation..."
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\System' 'AllowExperimentation' 'REG_DWORD' '0'

Write-Output "16. Blocking Edge reinstallation via Windows Update..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' 'InstallDefault' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault' 'REG_DWORD' '0'

Write-Output "Cleaning up component store..."
& 'dism' "/Image:$($ScratchDisk)\scratchdir" "/Cleanup-Image" "/StartComponentCleanup" "/Defer"

Write-Output "Removing temporary files..."
Remove-Item -Path "$ScratchDisk\scratchdir\Windows\WinSxS\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$ScratchDisk\scratchdir\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$ScratchDisk\scratchdir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# ---------[ UNLOAD INSTALL.WIM REGISTRY ]--------- #
Write-Output "Unmounting Registry..."
$unloadSuccess = $true
if (-not (Unload-OfflineRegistry -path HKLM\zCOMPONENTS)) { $unloadSuccess = $false }
if (-not (Unload-OfflineRegistry -path HKLM\zDEFAULT)) { $unloadSuccess = $false }
if (-not (Unload-OfflineRegistry -path HKLM\zNTUSER)) { $unloadSuccess = $false }
if (-not (Unload-OfflineRegistry -path HKLM\zSOFTWARE)) { $unloadSuccess = $false }
if (-not (Unload-OfflineRegistry -path HKLM\zSYSTEM)) { $unloadSuccess = $false }

if (-not $unloadSuccess) {
    Write-Error "Registry unmount failed! Discarding changes to prevent image corruption."
    Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Discard
    exit
}

Write-Output "Unmounting image..."
$dismountSuccess = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 3
    
    try {
        Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Save -ErrorAction Stop
        $dismountSuccess = $true
        break
    } catch {
        Write-Warning "Dismount attempt $attempt failed: $_"
        if ($attempt -eq 3) {
            Write-Error "Failed to dismount after 3 attempts. Discarding changes."
            Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Discard
            exit
        }
        Start-Sleep -Seconds 5
    }
}
if (-not $dismountSuccess) { exit }

Start-Sleep -Seconds 5

Write-Output "Exporting image..."
Dism.exe /Export-Image /SourceImageFile:"$ScratchDisk\tiny11\sources\install.wim" /SourceIndex:$index /DestinationImageFile:"$ScratchDisk\tiny11\sources\install2.wim" /Compress:max
Remove-Item -Path "$ScratchDisk\tiny11\sources\install.wim" -Force | Out-Null
Rename-Item -Path "$ScratchDisk\tiny11\sources\install2.wim" -NewName "install.wim" | Out-Null

Write-Output "Windows image completed. Continuing with boot.wim."
Start-Sleep -Seconds 2
Clear-Host
Write-Output "Mounting boot image:"
$wimFilePath = "$ScratchDisk\tiny11\sources\boot.wim"
& takeown "/F" $wimFilePath | Out-Null
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false

try {
    Mount-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\boot.wim -Index 2 -Path $ScratchDisk\scratchdir -ErrorAction Stop
} catch {
    Write-Error "Failed to mount boot.wim: $_"
    exit
}

Write-Output "Loading registry for boot.wim..."
reg load HKLM\zSOFTWARE $ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE | Out-Null
reg load HKLM\zSYSTEM $ScratchDisk\scratchdir\Windows\System32\config\SYSTEM | Out-Null

$currentControlSetNumBoot = 1
try {
    $csValBoot = & reg query "HKLM\zSYSTEM\Select" /v Current 2>$null
    if ($csValBoot -match 'Current\s+REG_DWORD\s+0x(\d+)') { $currentControlSetNumBoot = [int]"0x$($Matches[1])" }
} catch {}
$csPathBoot = "HKLM\zSYSTEM\ControlSet$($currentControlSetNumBoot.ToString('000'))"

Write-Output "Bypassing system requirements(on the setup image):"
Set-RegistryValue "$csPathBoot\Setup\LabConfig" 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPathBoot\Setup\LabConfig" 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPathBoot\Setup\LabConfig" 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPathBoot\Setup\LabConfig" 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPathBoot\Setup\LabConfig" 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue "$csPathBoot\Setup\MoSetup" 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

Write-Output "Unmounting boot.wim Registry..."
$bootUnloadSuccess = $true
if (-not (Unload-OfflineRegistry -path HKLM\zSOFTWARE)) { $bootUnloadSuccess = $false }
if (-not (Unload-OfflineRegistry -path HKLM\zSYSTEM)) { $bootUnloadSuccess = $false }

if (-not $bootUnloadSuccess) {
    Write-Error "Boot registry unmount failed! Discarding changes."
    Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Discard
    exit
}

Write-Output "Unmounting boot.wim image..."
$bootDismountSuccess = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 3
    try {
        Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Save -ErrorAction Stop
        $bootDismountSuccess = $true
        break
    } catch {
        Write-Warning "Boot dismount attempt $attempt failed: $_"
        if ($attempt -eq 3) {
            Write-Error "Failed to dismount boot.wim. Discarding changes."
            Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Discard
            exit
        }
        Start-Sleep -Seconds 5
    }
}
if (-not $bootDismountSuccess) { exit }

Start-Sleep -Seconds 5

Clear-Host
Write-Output "The tiny11 image is now completed. Proceeding with the making of the ISO..."

Write-Output "Creating ISO image..."
if ($hostArchitecture -eq "AMD64") { $adkArch = "amd64" } else { $adkArch = $hostArchitecture.ToLower() }
$ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$adkArch\Oscdimg"
$localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

if ([System.IO.Directory]::Exists($ADKDepTools)) {
    Write-Output "Will be using oscdimg.exe from system ADK."
    $OSCDIMG = "$ADKDepTools\oscdimg.exe"
} else {
    Write-Output "ADK folder not found. Will be using bundled oscdimg.exe."
    $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

    if (-not (Test-Path -Path $localOSCDIMGPath)) {
        Write-Output "Downloading oscdimg.exe..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath -ErrorAction Stop
        } catch {
            Write-Error "Failed to download oscdimg.exe."
            exit 1
        }
    }
    $OSCDIMG = $localOSCDIMGPath
}

Write-Output "Executing oscdimg..."
cmd /c "`"$OSCDIMG`" -m -o -u2 -udfver102 -bootdata:2#p0,e,b`"$ScratchDisk\tiny11\boot\etfsboot.com`"#pEF,e,b`"$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin`" `"$ScratchDisk\tiny11`" `"$PSScriptRoot\tiny11.iso`""

Write-Output "Creation completed! Press any key to exit the script..."
Read-Host "Press Enter to continue"
Write-Output "Performing Cleanup..."
Remove-Item -Path "$ScratchDisk\tiny11" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

Write-Output "Ejecting Iso drive"
try {
    $volume = Get-Volume -DriveLetter $DriveLetter[0] -ErrorAction SilentlyContinue
    if ($volume -and $volume.DriveType -eq 'CD-ROM') {
        $volume | Get-DiskImage | Dismount-DiskImage -ErrorAction Stop
        Write-Output "Iso drive ejected"
    } else {
        Write-Warning "Drive $DriveLetter not found or not a CD-ROM, skipping eject."
    }
} catch {
    Write-Warning "Could not eject ISO drive: $_"
}

Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue

Stop-Transcript
exit
