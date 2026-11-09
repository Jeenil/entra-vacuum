BeforeAll {
    Import-Module "$PSScriptRoot/../EntraVacuum/EntraVacuum.psd1" -Force

    function New-TestPolicy ($Active = $true, $Rule = 'user.department -eq "Engineering"') {
        @{
            id                       = 'policy-active-id'
            automaticRequestSettings = @{ requestAccessForAllowedTargets = $Active }
            specificAllowedTargets   = @(
                @{ '@odata.type' = '#microsoft.graph.attributeRuleMembers'; membershipRule = $Rule }
            )
        }
    }

    function New-TestAssignment ($Id, $UserId, $State = 'Delivered') {
        @{ id = $Id; state = $State; target = @{ objectId = $UserId; displayName = "Name $UserId" } }
    }

    function New-TestUser ($Id) {
        @{ id = $Id; displayName = "Name $Id"; userPrincipalName = "$Id@example.com" }
    }

    # Mocks Graph by URI. $Matching lists the users the real rule includes. Assignments are served
    # one per page to exercise paging.
    function Set-GraphMocks ($Policies, $Assignments = @(), $Users = @(), $Matching = @()) {
        $script:Policies    = $Policies
        $script:Assignments = $Assignments
        $script:Users       = $Users
        $script:Matching    = $Matching
        Mock -ModuleName EntraVacuum Invoke-MgGraphRequest {
            if ($Method -eq 'POST' -and $Uri -like '*evaluateDynamicMembership') {
                $memberId = ($Body | ConvertFrom-Json).memberId
                return @{ membershipRuleEvaluationResult = ($memberId -in $script:Matching) }
            }
            if ($Method -ne 'GET') { return }
            if ($Uri -like '*assignmentPolicies*') { return @{ value = @($script:Policies) } }
            if ($Uri -like '*/users?*')            { return @{ value = @($script:Users) } }
            if ($Uri -like '*/assignments?*') {
                if ($script:Assignments.Count -gt 1) {
                    return @{ value = @($script:Assignments[0]); '@odata.nextLink' = 'https://graph.microsoft.com/next-page' }
                }
                return @{ value = @($script:Assignments) }
            }
            if ($Uri -like '*next-page') { return @{ value = @($script:Assignments | Select-Object -Skip 1) } }
        }
    }
}

Describe 'Sync-EntraVacAccessPackage' {
    BeforeEach {
    }

    It 'makes no changes when drift detection returns nothing' {
        Set-GraphMocks -Policies @()
        Sync-EntraVacAccessPackage -AccessPackageId 'fake-id' -WarningAction SilentlyContinue
        Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 0 -ParameterFilter { $Method -eq 'POST' -and $Uri -notlike '*evaluateDynamicMembership' }
    }

    Context 'when there is drift' {
        BeforeEach {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-b' 'user-b') `
                -Users @((New-TestUser 'user-a'), (New-TestUser 'user-c')) `
                -Matching @('user-a', 'user-c')
        }

        It 'adminAdds missing users and adminRemoves stale assignments' {
            Sync-EntraVacAccessPackage -AccessPackageId 'fake-id'
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 2 -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*assignmentRequests' -and ($Body | ConvertFrom-Json).requestType -eq 'adminAdd' }
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 1 -ParameterFilter {
                $b = if ($Body) { $Body | ConvertFrom-Json }
                $Method -eq 'POST' -and $Uri -like '*assignmentRequests' -and $b.requestType -eq 'adminRemove' -and $b.assignment.id -eq 'assign-b'
            }
        }

        It 'sends nothing with -WhatIf' {
            Sync-EntraVacAccessPackage -AccessPackageId 'fake-id' -WhatIf
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 0 -ParameterFilter { $Method -eq 'POST' -and $Uri -notlike '*evaluateDynamicMembership' }
        }
    }

    Context 'when removals exceed MaxRemovals' {
        BeforeEach {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @((New-TestAssignment 'assign-b' 'user-b'), (New-TestAssignment 'assign-d' 'user-d')) `
                -Users @(New-TestUser 'user-a') -Matching @('user-a')
        }

        It 'throws and sends nothing' {
            { Sync-EntraVacAccessPackage -AccessPackageId 'fake-id' -MaxRemovals 1 } | Should -Throw
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 0 -ParameterFilter { $Method -eq 'POST' -and $Uri -notlike '*evaluateDynamicMembership' }
        }

        It 'proceeds with -Force' {
            Sync-EntraVacAccessPackage -AccessPackageId 'fake-id' -MaxRemovals 1 -Force
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 2 -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*assignmentRequests' -and ($Body | ConvertFrom-Json).requestType -eq 'adminRemove' }
        }
    }

    Context 'when a PartiallyDelivered assignment exists for a user still in target' {
        It 'reprocesses it instead of removing and re-adding' {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-a' 'user-a' 'PartiallyDelivered') `
                -Users @(New-TestUser 'user-a') -Matching @('user-a')
            Sync-EntraVacAccessPackage -AccessPackageId 'fake-id'
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 1 -ParameterFilter { $Uri -like '*/assign-a/reprocess' }
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 0 -ParameterFilter { $Uri -like '*assignmentRequests' }
        }
    }

    Context 'when an assignment is still Delivering' {
        It 'does not request it again' {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-a' 'user-a' 'Delivering') `
                -Users @(New-TestUser 'user-a')
            Sync-EntraVacAccessPackage -AccessPackageId 'fake-id'
            Should -Invoke -ModuleName EntraVacuum Invoke-MgGraphRequest -Times 0 -ParameterFilter { $Method -eq 'POST' -and $Uri -notlike '*evaluateDynamicMembership' }
        }
    }
}
