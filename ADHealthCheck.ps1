<# 
    ADHealthCheck.ps1
    -----------------
    This script performs a health check on Active Directory by:
      • Checking replication status on each Domain Controller.
      • Verifying that essential services (NTDS and DNS) are running.
      • Listing FSMO role holders.
      
    Any deviations (e.g., replication failures or stopped services) are flagged and
    compiled into a report file for further review.
    
    Note: This script requires the ActiveDirectory module (RSAT installed or run on a DC)
          and appropriate permissions to query AD objects.
#>

# Ensure the ActiveDirectory module is available
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "ActiveDirectory module not found. Please install RSAT or run this on a domain controller. 😞"
    exit 1
}
Import-Module ActiveDirectory

# Initialize the report array with a header
$report = @()
$report += "=== Active Directory Health Check Report ==="
$report += "Generated on: $(Get-Date)"
$report += "--------------------------------------------`n"

# Function: Check Replication Health for a Domain Controller
function Check-Replication {
    param (
        [Parameter(Mandatory=$true)]
        $DC
    )
    $result = @()
    $result += "Replication Check for DC: $($DC.HostName)"
    
    try {
        $repFailures = Get-ADReplicationFailure -Scope Domain -Target $DC.HostName -ErrorAction Stop
        if ($repFailures.Count -gt 0) {
            $result += "  [!] Replication Failures Detected: $($repFailures.Count)"
            foreach ($failure in $repFailures) {
                $result += "      - Partner: $($failure.Partner) | First Failure: $($failure.FirstFailureTime) | Failure Count: $($failure.FailureCount)"
            }
        } else {
            $result += "  [+] No replication failures detected."
        }
    }
    catch {
        $result += "  [!] Error retrieving replication failures: $_"
    }
    return $result
}

# Function: Check FSMO Role Health
function Check-FSMO {
    $result = @()
    $result += "FSMO Role Check:"
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $result += "  Schema Master:          $($domain.SchemaMaster)"
        $result += "  Domain Naming Master:   $($domain.DomainNamingMaster)"
        $result += "  RID Master:             $($domain.RIDMaster)"
        $result += "  PDC Emulator:           $($domain.PDCEmulator)"
        $result += "  Infrastructure Master:  $($domain.InfrastructureMaster)"
    }
    catch {
        $result += "  [!] Error retrieving FSMO roles: $_"
    }
    return $result
}

# Function: Check Essential Services on a Domain Controller (NTDS and DNS)
function Check-DCServices {
    param (
        [Parameter(Mandatory=$true)]
        $DC
    )
    $result = @()
    $result += "Service Check for DC: $($DC.HostName)"
    $servicesToCheck = @("NTDS", "DNS")
    foreach ($svc in $servicesToCheck) {
        try {
            $service = Get-Service -ComputerName $DC.HostName -Name $svc -ErrorAction Stop
            if ($service.Status -ne 'Running') {
                $result += "  [!] Service '$svc' is NOT running (Status: $($service.Status))."
            } else {
                $result += "  [+] Service '$svc' is running."
            }
        }
        catch {
            $result += "  [!] Could not retrieve service '$svc' on $($DC.HostName): $_"
        }
    }
    return $result
}

# Retrieve all Domain Controllers in the domain
try {
    $DCs = Get-ADDomainController -Filter * -ErrorAction Stop
}
catch {
    Write-Error "Failed to retrieve Domain Controllers: $_"
    exit 1
}

# Loop through each Domain Controller to perform health checks
foreach ($dc in $DCs) {
    $report += "============================================="
    $report += "Domain Controller: $($dc.HostName) (Site: $($dc.Site))"
    $report += (Check-Replication -DC $dc)
    $report += (Check-DCServices -DC $dc)
    $report += ""
}

# Append FSMO Role Check to the report
$report += "============================================="
$report += (Check-FSMO)
$report += "============================================="

# Determine overall outcome based on any deviations flagged
if ($report -match "\[\!\]") {
    $report += "`nOutcome: Deviations from best practices detected. Please review the issues above. 😬"
} else {
    $report += "`nOutcome: All checks passed! Your AD is in great shape. 😎"
}

# Write the report to a file with a timestamp
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = "AD_Health_Report_$timestamp.txt"
$report | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "AD Health Check complete. Report saved to: $reportFile" -ForegroundColor Green
