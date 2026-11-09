function Get-EntraVacAccessPackageDrift {
    <#
    .SYNOPSIS
        Returns users who should be assigned to an access package but are not, and vice versa.

    .DESCRIPTION
        Compares the expected membership (derived from the active auto-assignment policy's
        membershipRule) against actual assignments and returns a drift report without making any
        changes. Reads every page of results, so large packages are fully covered. Only
        Microsoft.Graph.Authentication (Invoke-MgGraphRequest) is needed.

        The rule is translated to a Graph user filter for a fast first pass. Every disagreement is
        then confirmed with Entra's evaluateDynamicMembership API using the real rule, so a user
        is only reported in ShouldAdd / ShouldRemove when Entra agrees. An assignment whose user
        was deleted from the directory is reported in ShouldRemove. If the API call fails the
        function throws and reports nothing.

        Assignment states handled:
          Delivered          - included in current membership check. A user who no longer matches
                               and already has an expiry date is in the grace period: reported in
                               InGracePeriod, not ShouldRemove (unless -IncludeGracePeriod).
          PartiallyDelivered - user in target: reported in ShouldReprocess.
                               User not in target: reported in ShouldRemove.
          Delivering         - in flight. Counted as assigned (never added again) and reported in
                               Delivering. Never reported for removal. If Entra confirms the
                               user no longer matches the rule, it is also listed in
                               DeliveringNotInRule (a likely stuck request to cancel in the portal).

        Microsoft only permits one auto-assignment policy per access package. If more than one
        active policy is detected this indicates a misconfiguration and an error is emitted.
        Ref: https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-auto-assignment-policy

    .PARAMETER AccessPackageId
        The object ID of the access package to inspect.

    .PARAMETER IncludeGracePeriod
        Also report assignments in ShouldRemove when Entra has already started their grace period
        (an expiry date is set). By default these are listed in InGracePeriod and left for Entra to
        remove when the grace period ends.

    .EXAMPLE
        Get-EntraVacAccessPackageDrift -AccessPackageId "ad524555-24ef-412a-8d20-e070c088a42d"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $AccessPackageId,

        [switch] $IncludeGracePeriod
    )

    # Ref: https://learn.microsoft.com/en-us/graph/api/entitlementmanagement-list-assignmentpolicies?view=graph-rest-1.0
    $policies = Invoke-EntraVacGraphGetAll `
        -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies?`$filter=accessPackage/id eq '$AccessPackageId'"

    # Validate the auto-assignment policy state.
    # Ref: https://learn.microsoft.com/en-us/graph/api/resources/accesspackageautomaticrequestsettings?view=graph-rest-1.0
    # Non-auto policies can carry an empty automaticRequestSettings object, so test the flag itself.
    $autoPolicies     = $policies | Where-Object { $null -ne $_.automaticRequestSettings.requestAccessForAllowedTargets }
    $activePolicies   = $autoPolicies | Where-Object { $_.automaticRequestSettings.requestAccessForAllowedTargets -eq $true }
    $inactivePolicies = $autoPolicies | Where-Object { $_.automaticRequestSettings.requestAccessForAllowedTargets -ne $true }

    if (-not $autoPolicies) {
        Write-Warning "No auto-assignment policy found for access package $AccessPackageId"
        return
    }

    if ($inactivePolicies) {
        Write-Warning "The auto-assignment policy for access package $AccessPackageId is inactive (requestAccessForAllowedTargets = false). Skipping."
        return
    }

    if (($activePolicies | Measure-Object).Count -gt 1) {
        Write-Error "Access package $AccessPackageId has more than one active auto-assignment policy. This is a misconfiguration - only one is supported. Resolve in the Entra portal before running this command."
        return
    }

    $activePolicy = $activePolicies | Select-Object -First 1

    # PartiallyDelivered = provisioning started but at least one resource role failed.
    # Delivering = still being provisioned; counted as assigned so it is not requested twice.
    # Ref: https://learn.microsoft.com/en-us/graph/api/entitlementmanagement-list-assignments?view=graph-rest-1.0
    $assignments = @(Invoke-EntraVacGraphGetAll `
        -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignments?`$filter=accessPackage/id eq '$AccessPackageId' and (state eq 'Delivered' or state eq 'PartiallyDelivered' or state eq 'Delivering')&`$expand=target")

    $deliveringAssignments = $assignments | Where-Object { $_.State -eq 'Delivering' }
    $settledAssignments    = $assignments | Where-Object { $_.State -ne 'Delivering' }
    $partialAssignments    = $assignments | Where-Object { $_.State -eq 'PartiallyDelivered' }
    $assignedUserIds       = $assignments | ForEach-Object { $_.Target.ObjectId }

    $membershipRule = $activePolicy.specificAllowedTargets |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.attributeRuleMembers' } |
        Select-Object -First 1 | ForEach-Object { $_.membershipRule }

    if ([string]::IsNullOrWhiteSpace($membershipRule)) {
        Write-Warning "The auto-assignment policy for access package $AccessPackageId has no membershipRule. Skipping to avoid unintended removals."
        return
    }

    # ConsistencyLevel + count required for advanced filter properties such as
    # onPremisesExtensionAttributes. Safe to use for all filter expressions.
    # Ref: https://learn.microsoft.com/en-us/graph/aad-advanced-queries?tabs=http
    $graphFilter = Convert-PolicyFilterToGraphFilter -PolicyFilter $membershipRule
    $targetUsers = @(Invoke-EntraVacGraphGetAll `
        -Uri "https://graph.microsoft.com/v1.0/users?`$filter=$graphFilter&`$select=id,displayName,userPrincipalName&`$top=999&`$count=true" `
        -Headers @{ ConsistencyLevel = 'eventual' })

    if (-not $targetUsers) {
        Write-Warning "The membershipRule for access package $AccessPackageId returned no users. Skipping to avoid unintended removals."
        return
    }

    $targetUserIds = $targetUsers | ForEach-Object { $_.id }

    # The translated filter is only a shortlist: Entra confirms every disagreement with the real
    # rule. A failed call throws, so nothing is reported from a partial answer.
    $isMember = {
        param ($UserId)
        try {
            # Ref: https://learn.microsoft.com/en-us/graph/api/group-evaluatedynamicmembership?view=graph-rest-beta
            $result = Invoke-MgGraphRequest -Method POST -ErrorAction Stop `
                -Uri 'https://graph.microsoft.com/beta/groups/evaluateDynamicMembership' `
                -ContentType 'application/json' `
                -Body (@{ memberId = $UserId; membershipRule = $membershipRule } | ConvertTo-Json)
        } catch {
            # A deleted user cannot match the rule. Any other failure stops the run.
            if ("$($_.Exception.Message) $($_.ErrorDetails.Message)" -match 'Request_ResourceNotFound') {
                Write-Verbose "User $UserId no longer exists in the directory."
                return $false
            }
            throw
        }
        if ($null -eq $result.membershipRuleEvaluationResult) {
            throw "evaluateDynamicMembership returned no result for user $UserId."
        }
        [bool] $result.membershipRuleEvaluationResult
    }

    $addCandidates    = $targetUsers | Where-Object { $_.id -notin $assignedUserIds }
    $leavers          = $settledAssignments | Where-Object { $_.Target.ObjectId -notin $targetUserIds }
    $inGrace          = $leavers | Where-Object { $_.Schedule.Expiration.EndDateTime -and -not $IncludeGracePeriod }
    $removeCandidates = $leavers | Where-Object { $_ -notin $inGrace }

    $shouldAdd      = [System.Collections.Generic.List[object]]::new()
    $excludedByRule = [System.Collections.Generic.List[object]]::new()
    foreach ($user in $addCandidates) {
        if (& $isMember $user.id) { $shouldAdd.Add($user) } else { $excludedByRule.Add($user) }
    }

    $deliveringNotInRule = $deliveringAssignments |
        Where-Object { $_.Target.ObjectId -notin $targetUserIds } |
        Where-Object { -not (& $isMember $_.Target.ObjectId) }

    [PSCustomObject]@{
        AccessPackageId    = $AccessPackageId
        AssignmentPolicyId = $activePolicy.id
        MembershipRule     = $membershipRule
        GraphFilter        = $graphFilter
        AssignmentsRead    = $assignments.Count
        TargetUsersRead    = $targetUsers.Count
        ShouldAdd          = $shouldAdd
        ShouldReprocess    = $partialAssignments | Where-Object { $_.Target.ObjectId -in $targetUserIds }
        ShouldRemove       = $removeCandidates | Where-Object { -not (& $isMember $_.Target.ObjectId) }
        InGracePeriod      = $inGrace
        Delivering         = $deliveringAssignments
        DeliveringNotInRule = $deliveringNotInRule
        ExcludedByRule     = $excludedByRule
    }
}
