<#
.SYNOPSIS
    Detects circular nesting issues among security groups in Active Directory.

.DESCRIPTION
    This script retrieves all security groups (with their 'member' attribute), builds a lookup 
    of group-to-group membership relationships (only considering group objects), and then 
    uses a recursive depth-first search to detect cycles in the nested groups. When a cycle is 
    found, it prints out the cycle and a recommendation to break the cycle.

.NOTES
    - This script requires the ActiveDirectory module. In PowerShell 7, you might need to use 
      Windows compatibility if not running on Windows.
    - Test carefully when processing ~67,000 groups.
#>

# Ensure the ActiveDirectory module is available
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "ActiveDirectory module not found. Please install/import it before running this script."
    return
}

# Retrieve all security groups with the 'member' property.
Write-Host "Fetching all security groups from Active Directory... (this may take a while)" -ForegroundColor Cyan
$allGroups = Get-ADGroup -Filter * -Properties member

# Build a hash table of group DistinguishedNames to group Names (for quick lookup)
$groupDNs = @{}
foreach ($group in $allGroups) {
    $groupDNs[$group.DistinguishedName] = $group.Name
}

# Build a graph: key = group DN, value = list of nested group DNs (only those that are security groups)
# We avoid extra lookups by checking if the member DN is in our hash table.
$groupGraph = @{}
foreach ($group in $allGroups) {
    # Initialize an empty array for each group node.
    $groupGraph[$group.DistinguishedName] = @()
    
    if ($group.member) {
        foreach ($memberDN in $group.member) {
            if ($groupDNs.ContainsKey($memberDN)) {
                # Only add if the member is also a group (exists in our list)
                $groupGraph[$group.DistinguishedName] += $memberDN
            }
        }
    }
}

Write-Host "Graph built. Starting cycle detection..." -ForegroundColor Cyan

# Recursive DFS function to detect cycles.
function Find-Cycle {
    param (
        [string]$current,
        [System.Collections.Generic.HashSet[string]]$visited,
        [System.Collections.Generic.HashSet[string]]$stack,
        [System.Collections.Generic.List[string]]$path
    )
    # If current group is already in the recursion stack, we've found a cycle!
    if ($stack.Contains($current)) {
        # Determine where in the path the cycle started
        $cycleStartIndex = $path.IndexOf($current)
        $cycle = $path[$cycleStartIndex..($path.Count - 1)]
        return ,$cycle  # Return as an array (even if single cycle)
    }
    
    # If we've already visited this node (in a previous DFS), skip it.
    if ($visited.Contains($current)) {
        return $null
    }
    
    $visited.Add($current) | Out-Null
    $stack.Add($current) | Out-Null
    $path.Add($current) | Out-Null

    foreach ($child in $groupGraph[$current]) {
        $result = Find-Cycle -current $child -visited $visited -stack $stack -path $path
        if ($result) {
            return $result
        }
    }
    
    # Backtrack: remove the current node from the stack and path.
    $stack.Remove($current) | Out-Null
    $path.RemoveAt($path.Count - 1)
    return $null
}

# Main cycle detection loop
$cyclesFound = @()
# This hash set will track all nodes we have already processed via DFS.
$globalVisited = [System.Collections.Generic.HashSet[string]]::new()

foreach ($groupDN in $groupGraph.Keys) {
    if (-not $globalVisited.Contains($groupDN)) {
        # Create new DFS tracking sets for this branch.
        $visited = [System.Collections.Generic.HashSet[string]]::new()
        $stack   = [System.Collections.Generic.HashSet[string]]::new()
        $path    = New-Object System.Collections.Generic.List[string]

        $cycle = Find-Cycle -current $groupDN -visited $visited -stack $stack -path $path
        
        # Add all nodes visited in this DFS to the global visited set.
        foreach ($v in $visited) {
            $globalVisited.Add($v) | Out-Null
        }
        
        if ($cycle) {
            $cyclesFound += ,$cycle
        }
    }
}

# Output the results
if ($cyclesFound.Count -eq 0) {
    Write-Host "No circular nesting issues detected! 🎉" -ForegroundColor Green
} else {
    Write-Host "Circular nesting cycles detected:" -ForegroundColor Yellow
    foreach ($cycle in $cyclesFound) {
        # Convert DistinguishedNames to friendly group names where possible
        $cycleNames = $cycle | ForEach-Object {
            if ($groupDNs.ContainsKey($_)) {
                $groupDNs[$_]
            } else {
                $_
            }
        }
        # Complete the cycle by showing the first group again at the end
        $cycleDisplay = $cycleNames + $cycleNames[0]
        Write-Host ("Cycle: " + ($cycleDisplay -join " -> "))
        Write-Host "Recommendation: Review the memberships above and remove at least one of the nested references to break the cycle."
        Write-Host ""
    }
}
