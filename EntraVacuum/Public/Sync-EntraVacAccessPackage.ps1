function Sync-EntraVacAccessPackage {
    <#
    .SYNOPSIS
        Syncs membership for an Entra ID access package based on its auto-assignment policy filter.

    .DESCRIPTION
        Uses Get-EntraVacAccessPackageDrift to find what differs (all pages, confirmed with
        Entra's evaluateDynamicMembership), then performs adminAdd/reprocess/adminRemove.
        Nothing is sent when -WhatIf is used, or when drift detection fails.

        Assignment states handled:
          Delivered          - user in target: keep. Not in target: adminRemove.
          PartiallyDelivered - user in target: reprocess. Not in target: adminRemove.
          Delivering         - in flight: left alone.

        Microsoft only permits one auto-assignment policy per access package. If more than one
        active policy is detected this indicates a misconfiguration and an error is emitted.
        Ref: https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-auto-assignment-policy

    .PARAMETER AccessPackageId
        The object ID of the access package to sync.

    .PARAMETER MaxRemovals
        Safety cap. If more assignments than this would be removed, nothing is sent and an error is
        raised, because adminRemove skips the policy's grace period. Defaults to 100. With -WhatIf
        the planned actions are still listed and a warning is shown instead.

    .PARAMETER IncludeGracePeriod
        Also remove assignments that are already in their grace period. By default Entra is left to
        remove them when the grace period ends.

    .PARAMETER Force
        Allow more removals than MaxRemovals.

    .PARAMETER WhatIf
        Preview changes without applying them.

    .EXAMPLE
        Sync-EntraVacAccessPackage -AccessPackageId "ad524555-24ef-412a-8d20-e070c088a42d"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string] $AccessPackageId,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $MaxRemovals = 100,

        [switch] $IncludeGracePeriod,

        [switch] $Force
    )

    $drift = Get-EntraVacAccessPackageDrift -AccessPackageId $AccessPackageId -IncludeGracePeriod:$IncludeGracePeriod
    if (-not $drift) { return }

    $toAdd       = @($drift.ShouldAdd)
    $toReprocess = @($drift.ShouldReprocess)
    $toRemove    = @($drift.ShouldRemove)

    Write-Verbose "Access package $AccessPackageId - adding $($toAdd.Count), reprocessing $($toReprocess.Count), removing $($toRemove.Count)"

    if ($toRemove.Count -gt $MaxRemovals -and -not $Force) {
        $message = "Access package $AccessPackageId would remove $($toRemove.Count) assignments, which is over the limit of $MaxRemovals. Review with -WhatIf, then rerun with -Force or a higher -MaxRemovals."
        if ($WhatIfPreference) { Write-Warning $message } else { throw $message }
    }

    # Ref: https://learn.microsoft.com/en-us/graph/api/entitlementmanagement-post-assignmentrequests?view=graph-rest-1.0
    $requestsUri = 'https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentRequests'
    foreach ($user in $toAdd) {
        if ($PSCmdlet.ShouldProcess("$($user.userPrincipalName) ($($user.id))", "adminAdd to access package $AccessPackageId")) {
            Invoke-MgGraphRequest -Method POST -Uri $requestsUri -ContentType 'application/json' -Body (@{
                requestType = 'adminAdd'
                assignment  = @{
                    targetId           = $user.id
                    assignmentPolicyId = $drift.AssignmentPolicyId
                    accessPackageId    = $AccessPackageId
                }
            } | ConvertTo-Json -Depth 5) | Out-Null
        }
    }

    # Reprocess PartiallyDelivered assignments where the user still belongs.
    # Ref: https://learn.microsoft.com/en-us/graph/api/accesspackageassignment-reprocess?view=graph-rest-1.0
    foreach ($assignment in $toReprocess) {
        $name = $assignment.Target.DisplayName ?? $assignment.Target.ObjectId
        if ($PSCmdlet.ShouldProcess("$name ($($assignment.Target.ObjectId))", "reprocess PartiallyDelivered assignment in access package $AccessPackageId")) {
            Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignments/$($assignment.id)/reprocess" | Out-Null
        }
    }

    foreach ($assignment in $toRemove) {
        $name = $assignment.Target.DisplayName ?? $assignment.Target.ObjectId
        if ($PSCmdlet.ShouldProcess("$name ($($assignment.Target.ObjectId))", "adminRemove from access package $AccessPackageId")) {
            Invoke-MgGraphRequest -Method POST -Uri $requestsUri -ContentType 'application/json' -Body (@{
                requestType = 'adminRemove'
                assignment  = @{ id = $assignment.id }
            } | ConvertTo-Json -Depth 5) | Out-Null
        }
    }
}
