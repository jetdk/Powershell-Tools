<#
.SYNOPSIS
    Creates a gMSA in Active Directory and sets up a Scheduled Task that runs a PowerShell 7 script under the gMSA.

.DESCRIPTION
    This script will:
      1. Check for and import the ActiveDirectory module.
      2. Create (or verify the existence of) a gMSA in AD.
      3. Install the gMSA locally.
      4. Prompt for scheduled task details (including trigger info and the task owner).
      5. Create a scheduled task that runs a PowerShell 7 script under the gMSA.
      6. Embed owner details in the task's RegistrationInfo (documentation for who set it up).

.NOTES
    - Run this script in an elevated PowerShell 7 session.
    - Ensure RSAT tools (and the ActiveDirectory module) are installed.
    - This script assumes Windows 10/Server 2016 or later (for the RegistrationInfo feature).
#>

# ----- Pre-check: Import ActiveDirectory Module -----
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "ActiveDirectory module not found. Please install RSAT tools." -ErrorAction Stop
}

# ----- Part 1: Create or Verify the gMSA in Active Directory -----

# Prompt for gMSA name (do NOT include the trailing $)
$gMSAName = Read-Host "Enter the gMSA name (without the trailing '$')"

# Check if the gMSA already exists
$existingGmsa = Get-ADServiceAccount -Identity $gMSAName -ErrorAction SilentlyContinue
if ($existingGmsa) {
    Write-Host "gMSA '$gMSAName' already exists. Skipping creation." -ForegroundColor Yellow
} else {
    # Prompt for allowed principals (computers or groups allowed to use this gMSA)
    $principals = Read-Host "Enter allowed principals (comma-separated, e.g., Domain\Computer1,Domain\Computer2)"
    $principalsArray = $principals.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    
    try {
        Write-Host "Creating gMSA '$gMSAName'..." -ForegroundColor Cyan
        New-ADServiceAccount -Name $gMSAName -PrincipalsAllowedToRetrieveManagedPassword $principalsArray -Verbose
        Write-Host "gMSA '$gMSAName' created successfully." -ForegroundColor Green
    } catch {
        Write-Error "Failed to create gMSA '$gMSAName': $_"
        exit 1
    }
}

# Install the gMSA on the local machine (if not already installed)
try {
    Write-Host "Installing gMSA '$gMSAName' locally..." -ForegroundColor Cyan
    Install-ADServiceAccount -Identity $gMSAName -Verbose
    Write-Host "gMSA '$gMSAName' installed locally successfully." -ForegroundColor Green
} catch {
    Write-Error "Failed to install gMSA '$gMSAName' locally: $_"
    exit 1
}

# ----- Part 2: Create a Scheduled Task with Owner Documentation -----

# Prompt for scheduled task details
$taskName = Read-Host "Enter the scheduled task name"
$scriptPath = Read-Host "Enter the full path to the PowerShell script to run (e.g., C:\Scripts\MyScript.ps1)"
if (-not (Test-Path $scriptPath)) {
    Write-Error "Script path '$scriptPath' does not exist. Exiting."
    exit 1
}

$triggerType = Read-Host "Enter the trigger type (Daily, Weekly, or Once)"
$scheduleTime = Read-Host "Enter the start time (HH:mm in 24-hour format)"
# Basic time format validation
if (-not ($scheduleTime -match '^\d{2}:\d{2}$')) {
    Write-Error "Invalid time format. Please use HH:mm (24-hour format). Exiting."
    exit 1
}

# Get additional trigger-specific details
switch ($triggerType.ToLower()) {
    "daily" {
        $daysInterval = Read-Host "Enter the interval in days (e.g., 1 for every day)"
        if (-not ($daysInterval -as [int])) {
            Write-Error "Invalid interval. Exiting."
            exit 1
        }
    }
    "weekly" {
        $daysInput = Read-Host "Enter the days of the week (comma-separated, e.g., Mon,Wed,Fri)"
        $daysInterval = $daysInput.Split(",") | ForEach-Object { 
            try { 
                [System.DayOfWeek]::Parse($_.Trim()) 
            } catch {
                Write-Host "WARNING: '$_' is not a valid day. Skipping it." -ForegroundColor Yellow
            }
        }
        if (-not $daysInterval) {
            Write-Error "No valid days provided. Exiting."
            exit 1
        }
    }
    "once" {
        # No extra input needed.
    }
    default {
        Write-Error "Invalid trigger type specified. Exiting."
        exit 1
    }
}

# Prompt for the task owner (to document who created/owns the task)
$taskOwner = Read-Host "Enter the owner of the scheduled task (e.g., username or email)"

# Determine the PowerShell 7 executable path
$pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)?.Source
if (-not $pwshPath) {
    Write-Warning "Could not auto-detect PowerShell 7. Falling back to default path."
    $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
}

# Create the action to run the provided script
$action = New-ScheduledTaskAction -Execute $pwshPath -Argument "-NoProfile -File `"$scriptPath`""

# Create the trigger based on the provided trigger type
switch ($triggerType.ToLower()) {
    "daily" {
        $trigger = New-ScheduledTaskTrigger -Daily -At $scheduleTime -DaysInterval $daysInterval
    }
    "weekly" {
        $trigger = New-ScheduledTaskTrigger -Weekly -At $scheduleTime -DaysOfWeek $daysInterval
    }
    "once" {
        $trigger = New-ScheduledTaskTrigger -Once -At $scheduleTime
    }
}

# Define additional task settings
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 60)

# Get the current domain name (assumes you are connected to AD)
try {
    $domainName = (Get-ADDomain).DNSRoot
} catch {
    Write-Error "Unable to determine the domain. Ensure you are connected to Active Directory."
    exit 1
}

# Construct the gMSA user in the format Domain\gMSAName$
$gMSAUser = "$domainName\$gMSAName`$"

# Create the principal for the scheduled task (using the gMSA)
$principal = New-ScheduledTaskPrincipal -UserId $gMSAUser -LogonType ServiceAccount -RunLevel Highest

# Create RegistrationInfo with owner documentation.
# Note: New-ScheduledTaskRegistrationInfo is available on Windows 10/Server 2016 or later.
try {
    $regInfo = New-ScheduledTaskRegistrationInfo -Author $taskOwner -Description "Scheduled Task created by $taskOwner using gMSA: $gMSAUser"
} catch {
    Write-Warning "Unable to create registration info. The task will be created without owner metadata."
    $regInfo = $null
}

# Assemble the scheduled task definition (include RegistrationInfo if available)
if ($regInfo) {
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -RegistrationInfo $regInfo
} else {
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal
}

# Idempotence: Remove an existing task with the same name if it exists
try {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "A scheduled task named '$taskName' already exists and will be removed." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
} catch {
    Write-Warning "Could not verify existing scheduled tasks: $_"
}

# Register the scheduled task
try {
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force
    Write-Host "Scheduled task '$taskName' created successfully under gMSA '$gMSAUser'." -ForegroundColor Green
} catch {
    Write-Error "Failed to register the scheduled task: $_"
    exit 1
}

Write-Host "All done! Your scheduled task is set up and the owner '$taskOwner' has been documented. Enjoy the automation 😎" -ForegroundColor Cyan
