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

Describe 'Get-EntraVacAccessPackageDrift' {
    It 'warns and returns nothing when there is no auto-assignment policy' {
        Set-GraphMocks -Policies @()
        $result = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings | Should -Not -BeNullOrEmpty
        $result   | Should -BeNullOrEmpty
    }

    It 'warns and returns nothing when the policy is inactive' {
        Set-GraphMocks -Policies @(New-TestPolicy -Active $false)
        $result = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings | Should -Not -BeNullOrEmpty
        $result   | Should -BeNullOrEmpty
    }

    It 'errors when more than one active auto-assignment policy exists' {
        Set-GraphMocks -Policies @((New-TestPolicy), (New-TestPolicy))
        $result = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id' -ErrorAction SilentlyContinue -ErrorVariable errs
        $errs   | Should -Not -BeNullOrEmpty
        $result | Should -BeNullOrEmpty
    }

    It 'warns and returns nothing when the rule is empty' {
        Set-GraphMocks -Policies @(New-TestPolicy -Rule '')
        $result = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings | Should -Not -BeNullOrEmpty
        $result   | Should -BeNullOrEmpty
    }

    It 'warns and returns nothing when the rule matches no users' {
        Set-GraphMocks -Policies @(New-TestPolicy) -Users @()
        $result = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings | Should -Not -BeNullOrEmpty
        $result   | Should -BeNullOrEmpty
    }

    Context 'when there is drift' {
        BeforeEach {
            # user-b is assigned but no longer matches; user-a and user-c match but are not assigned
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-b' 'user-b') `
                -Users @((New-TestUser 'user-a'), (New-TestUser 'user-c')) `
                -Matching @('user-a', 'user-c')
        }

        It 'reads assignments from every page' {
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            $drift.AssignmentsRead | Should -Be 1
        }

        It 'reports who to add and who to remove' {
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            $drift.ShouldAdd.id | Should -Be @('user-a', 'user-c')
            $drift.ShouldRemove.Target.ObjectId | Should -Be 'user-b'
            $drift.AssignmentPolicyId | Should -Be 'policy-active-id'
        }
    }

    Context 'when a PartiallyDelivered assignment exists for a user still in target' {
        It 'reports it in ShouldReprocess only' {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-a' 'user-a' 'PartiallyDelivered') `
                -Users @(New-TestUser 'user-a') -Matching @('user-a')
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            ($drift.ShouldReprocess | Measure-Object).Count | Should -Be 1
            ($drift.ShouldAdd       | Measure-Object).Count | Should -Be 0
            ($drift.ShouldRemove    | Measure-Object).Count | Should -Be 0
        }
    }

    Context 'when the translated filter disagrees with Entra' {
        BeforeEach {
            # user-a is in the translated result but excluded by the real rule; user-x is assigned and still matches
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-x' 'user-x') `
                -Users @(New-TestUser 'user-a') -Matching @('user-x')
        }

        It 'does not add or remove anyone Entra says is correct' {
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            ($drift.ShouldAdd    | Measure-Object).Count | Should -Be 0
            ($drift.ShouldRemove | Measure-Object).Count | Should -Be 0
        }

        It 'lists the excluded user in ExcludedByRule' {
            (Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id').ExcludedByRule.id | Should -Contain 'user-a'
        }
    }

    Context 'when an assignment is still Delivering' {
        It 'reports it as Delivering and never as ShouldAdd or ShouldRemove' {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-a' 'user-a' 'Delivering') `
                -Users @(New-TestUser 'user-a')
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            $drift.Delivering.Target.ObjectId | Should -Contain 'user-a'
            ($drift.ShouldAdd    | Measure-Object).Count | Should -Be 0
            ($drift.ShouldRemove | Measure-Object).Count | Should -Be 0
        }
    }

    Context 'when a Delivering assignment is for a user who no longer matches' {
        It 'lists it in DeliveringNotInRule and does not remove it' {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @((New-TestAssignment 'assign-k' 'user-k' 'Delivering'), (New-TestAssignment 'assign-a' 'user-a' 'Delivering')) `
                -Users @(New-TestUser 'user-a') -Matching @('user-a')
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            $drift.DeliveringNotInRule.Target.ObjectId | Should -Be 'user-k'
            ($drift.ShouldRemove | Measure-Object).Count | Should -Be 0
        }
    }

    Context 'when an assigned user has been deleted from the directory' {
        It 'reports the assignment in ShouldRemove' {
            Set-GraphMocks -Policies @(New-TestPolicy) `
                -Assignments @(New-TestAssignment 'assign-gone' 'user-gone') `
                -Users @(New-TestUser 'user-a') -Matching @('user-a')
            Mock -ModuleName EntraVacuum Invoke-MgGraphRequest { throw 'Request_ResourceNotFound: Resource does not exist' } -ParameterFilter { $Method -eq 'POST' }
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            $drift.ShouldRemove.Target.ObjectId | Should -Be 'user-gone'
        }
    }

    Context 'when a user who left the rule is already in the grace period' {
        BeforeEach {
            $grace = New-TestAssignment 'assign-g' 'user-g'
            $grace.Schedule = @{ Expiration = @{ EndDateTime = (Get-Date).AddDays(5) } }
            Set-GraphMocks -Policies @(New-TestPolicy) -Assignments @($grace, (New-TestAssignment 'assign-n' 'user-n')) `
                -Users @(New-TestUser 'user-a') -Matching @('user-a')
        }

        It 'leaves the grace-period assignment to Entra and removes the other' {
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id'
            $drift.InGracePeriod.Target.ObjectId | Should -Be 'user-g'
            $drift.ShouldRemove.Target.ObjectId  | Should -Be 'user-n'
        }

        It 'removes both with -IncludeGracePeriod' {
            $drift = Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id' -IncludeGracePeriod
            $drift.ShouldRemove.Target.ObjectId | Should -Contain 'user-g'
            ($drift.InGracePeriod | Measure-Object).Count | Should -Be 0
        }
    }

    Context 'when evaluateDynamicMembership fails' {
        It 'throws instead of reporting a partial result' {
            Set-GraphMocks -Policies @(New-TestPolicy) -Users @(New-TestUser 'user-a')
            Mock -ModuleName EntraVacuum Invoke-MgGraphRequest { throw '403 Forbidden' } -ParameterFilter { $Method -eq 'POST' }
            { Get-EntraVacAccessPackageDrift -AccessPackageId 'fake-id' } | Should -Throw
        }
    }
}
