<#
.SYNOPSIS
    Ensures Active Directory is configured to support gMSA by checking for an existing KDS root key.
    If not found, it creates one. In a development environment, it uses instant provisioning.

.DESCRIPTION
    This script checks if your domain supports gMSA by verifying:
      - The domain functional level (must be at least Windows Server 2012).
      - The existence of a KDS root key.
    If no root key is found, the script will prompt for the environment type:
      - For "development", it will create a KDS root key using the -EffectiveImmediately parameter.
      - For "production", it creates the key without instant provisioning (the key becomes effective after 10 hours).

.NOTES
    Run this script as a Domain Admin.
    Ensure the Active Directory module is installed on this machine.
#>

# Import the Active Directory module
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "The Active Directory module could not be imported. Please ensure it is installed and try again."
    exit
}

# Prompt for the environment type
$envType = Read-Host "Enter environment type (development/production)"

if (($envType -ne "development") -and ($envType -ne "production")) {
    Write-Error "Invalid environment type specified. Please enter 'development' or 'production'."
    exit
}

# Check if the domain functional level supports gMSA
$domain = Get-ADDomain
$validLevels = @("Windows2012Domain", "Windows2012R2Domain", "Windows2016Domain", "Windows2019Domain", "Windows2022Domain")
if ($validLevels -notcontains $domain.DomainMode) {
    Write-Error "Your domain functional level ($($domain.DomainMode)) does not support gMSA. Please upgrade to at least Windows Server 2012."
    exit
}

# Check for an existing KDS root key
try {
    $kdsRootKeys = Get-KdsRootKey -ErrorAction Stop
} catch {
    $kdsRootKeys = @()
}

if (-not $kdsRootKeys) {
    Write-Host "No KDS Root Key found. Proceeding to create one..." -ForegroundColor Yellow
    if ($envType -eq "development") {
        Write-Host "Development environment detected. Using instant provisioning (-EffectiveImmediately)." -ForegroundColor Green
        try {
            Add-KdsRootKey -EffectiveImmediately -ErrorAction Stop
            Write-Host "KDS Root Key created successfully with instant provisioning."
        } catch {
            Write-Error "Error creating KDS Root Key with instant provisioning: $_"
            exit
        }
    } else {
        Write-Host "Production environment detected. Creating KDS Root Key without instant provisioning (effective after 10 hours)." -ForegroundColor Green
        try {
            Add-KdsRootKey -ErrorAction Stop
            Write-Host "KDS Root Key created successfully."
        } catch {
            Write-Error "Error creating KDS Root Key: $_"
            exit
        }
    }
} else {
    Write-Host "KDS Root Key(s) already exist. Your Active Directory is already configured for gMSA." -ForegroundColor Cyan
}

Write-Host "Active Directory is now configured to support gMSA." -ForegroundColor Cyan
