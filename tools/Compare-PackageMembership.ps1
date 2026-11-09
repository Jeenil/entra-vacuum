#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Read-only: explains why access packages that should behave the same do not.

.DESCRIPTION
    Fast by design - it never pages through every assignment.
      1. Policies: compares each package's auto-assignment policy (rule hash, removal/grace settings,
         expiration, last modified). A difference here usually explains different membership.
      2. Recent changes (-RecentDays): counts recent assignment requests per package by type and state,
         e.g. systemRemove vs systemAdd, to show who dropped out and when.
      3. Users (-UserPrincipalName): for specific users, shows their assignment state in each package
         and what evaluateDynamicMembership says about the rule.

    Nothing is created, changed or removed.
    Connect first: Connect-MgGraph -Scopes EntitlementManagement.Read.All, User.Read.All, GroupMember.Read.All
    Section 3 additionally needs Groups Administrator, Global Administrator or Intune Administrator active.

.EXAMPLE
    ./Compare-PackageMembership.ps1 -DisplayNameLike '*-region'

.EXAMPLE
    ./Compare-PackageMembership.ps1 -DisplayNameLike '*-region' -RecentDays 14 -UserPrincipalName a@contoso.com
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param (
    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [string[]] $AccessPackageId,

    # Wildcard matched client-side against package display names, e.g. '*-region'.
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string] $DisplayNameLike,

    # Section 2: look back this many days. 0 skips it.
    [int] $RecentDays = 0,

    # Section 2: requestType can't be filtered server-side and systemUpdate noise is huge, so cap the pages read (100 rows each, newest first).
    [int] $MaxRequestPages = 5,

    # Section 3: users to check in every package. Empty skips it.
    [string[]] $UserPrincipalName
)

$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    throw 'Not connected. Run Connect-MgGraph -Scopes EntitlementManagement.Read.All, User.Read.All, GroupMember.Read.All'
}

function Get-AllPage ([string] $Uri, [int] $MaxPages = [int]::MaxValue) {
    while ($Uri -and $MaxPages-- -gt 0) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $page.value
        $Uri = $page.'@odata.nextLink'
    }
}

function Get-RuleHash ([string] $Rule) {
    $normalised = ($Rule -replace '\s+', ' ').Trim()
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalised))).Substring(0, 12)
}

$em = '/v1.0/identityGovernance/entitlementManagement'

$packages = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    Get-AllPage "$em/accessPackages?`$select=id,displayName" | Where-Object displayName -like $DisplayNameLike
} else {
    $AccessPackageId | ForEach-Object { Invoke-MgGraphRequest -Method GET -Uri "$em/accessPackages/$_" }
}
if (@($packages).Count -lt 2) { throw 'Need at least two packages to compare.' }

$data = foreach ($p in $packages) {
    $policy = Get-AllPage "$em/assignmentPolicies?`$filter=accessPackage/id eq '$($p.id)'" |
        Where-Object { $_.automaticRequestSettings.requestAccessForAllowedTargets -eq $true } |
        Select-Object -First 1
    $rule = $policy.specificAllowedTargets |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.attributeRuleMembers' } |
        Select-Object -First 1 -ExpandProperty membershipRule
    [PSCustomObject]@{
        Name     = $p.displayName
        Id       = $p.id
        Rule     = $rule
        Hash     = if ($rule) { Get-RuleHash $rule } else { '<no rule>' }
        Settings = ($policy.automaticRequestSettings | ConvertTo-Json -Compress -Depth 5)
        Expires  = ($policy.expiration | ConvertTo-Json -Compress -Depth 5)
        Modified = $policy.modifiedDateTime
    }
}

Write-Information "`n=== 1. Auto-assignment policy per package" -InformationAction Continue
$data | Format-List Name, Hash, Modified, Settings, Expires

foreach ($prop in 'Hash', 'Settings', 'Expires') {
    if (@($data.$prop | Sort-Object -Unique).Count -gt 1) {
        Write-Warning "$prop differs between packages - that can explain different membership."
    }
}

if ($RecentDays -gt 0) {
    Write-Information "=== 2. Assignment requests in the last $RecentDays days" -InformationAction Continue
    $since = (Get-Date).AddDays(-$RecentDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $data | ForEach-Object {
        $pkg = $_.Name
        $requests = @(Get-AllPage "$em/assignmentRequests?`\$filter=accessPackage/id eq '$($_.Id)' and createdDateTime ge $since" -MaxPages $MaxRequestPages)
        $oldest = ($requests.createdDateTime | Sort-Object | Select-Object -First 1)
        Write-Information "$pkg`: sampled $($requests.Count) requests, back to $oldest" -InformationAction Continue
        $requests | Group-Object requestType, state |
            ForEach-Object { [PSCustomObject]@{ Package = $pkg; RequestTypeAndState = $_.Name; Count = $_.Count } }
    } | Format-Table -AutoSize
}

if ($UserPrincipalName) {
    Write-Information "=== 3. Per-user state and rule evaluation" -InformationAction Continue
    $rows = foreach ($upn in $UserPrincipalName) {
        $user = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users/$upn`?`$select=id,userPrincipalName"
        $row = [ordered]@{ User = $user.userPrincipalName }
        foreach ($d in $data) {
            $a = Get-AllPage "$em/assignments?`$filter=accessPackage/id eq '$($d.Id)' and target/objectId eq '$($user.id)'" |
                Select-Object -First 1
            $match = try {
                (Invoke-MgGraphRequest -Method POST -Uri '/beta/groups/evaluateDynamicMembership' -ContentType 'application/json' `
                    -Body (@{ memberId = $user.id; membershipRule = $d.Rule } | ConvertTo-Json)).membershipRuleEvaluationResult
            } catch {
                'error (needs Groups/Global Administrator)'
            }
            $row[$d.Name] = "$($a.state ?? '<none>') / rule=$match"
        }
        [PSCustomObject]$row
    }
    $rows | Format-List
    Write-Information @'
How to read section 3:
  <none> / rule=True       -> should have been added; auto-assignment missed them
  expired / rule=True      -> matches again but was not re-added
  delivered / rule=False   -> should be removed; often inside the grace period
'@ -InformationAction Continue
}
