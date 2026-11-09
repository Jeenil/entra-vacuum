# entra-vacuum

Entra ID desired-state management for access packages. Reconciles assignments against auto-assignment policy filters faster than the built-in 24-hour cycle.

[![Lint](https://github.com/Jeenil/entra-vacuum/actions/workflows/lint.yml/badge.svg)](https://github.com/Jeenil/entra-vacuum/actions/workflows/lint.yml)
[![Test](https://github.com/Jeenil/entra-vacuum/actions/workflows/test.yml/badge.svg)](https://github.com/Jeenil/entra-vacuum/actions/workflows/test.yml)

## Install

```powershell
Install-Module -Name EntraVacuum -Scope CurrentUser
```

## Requirements

- PowerShell 7.2+
- Microsoft.Graph.Authentication 2.0.0+
- Drift checks call `evaluateDynamicMembership`, which needs the Groups Administrator (or Global/Intune Administrator) role, activated in PIM before connecting. Sync also needs the `EntitlementManagement.ReadWrite.All` scope.

## Usage

```powershell
Connect-MgGraph -Scopes "User.Read.All", "EntitlementManagement.ReadWrite.All"

# Preview what would change
Get-EntraVacAccessPackageDrift -AccessPackageId "<package-id>"

# Sync assignments
Sync-EntraVacAccessPackage -AccessPackageId "<package-id>"

# Dry run
Sync-EntraVacAccessPackage -AccessPackageId "<package-id>" -WhatIf
```

Safety options on `Sync-EntraVacAccessPackage`:

- `-MaxRemovals` (default 100): refuses to send anything if more assignments than this would be removed. `-Force` overrides it.
- `-IncludeGracePeriod`: also removes users already in their grace period. By default Entra removes them when the grace period ends.

## Assignment state handling

`Sync-EntraVacAccessPackage` handles all active assignment states:

| State | User in target | Action |
|---|---|---|
| `Delivered` | Yes | Keep |
| `Delivered` | No | adminRemove (skipped if already in the grace period) |
| `PartiallyDelivered` | Yes | Reprocess ([ref](https://learn.microsoft.com/en-us/graph/api/accesspackageassignment-reprocess?view=graph-rest-1.0)) |
| `PartiallyDelivered` | No | adminRemove |
| `Delivering` | Any | Left alone (counted as assigned); listed in `Delivering`, and in `DeliveringNotInRule` if the user no longer matches |
| No assignment | Yes | adminAdd |

`Get-EntraVacAccessPackageDrift` surfaces these as `ShouldAdd`, `ShouldReprocess`, and `ShouldRemove`.

## Policy requirements

Both functions require the access package to have an auto-assignment policy
([`accessPackageAssignmentPolicy`](https://learn.microsoft.com/en-us/graph/api/resources/accesspackageassignmentpolicy?view=graph-rest-1.0))
with [`automaticRequestSettings`](https://learn.microsoft.com/en-us/graph/api/resources/accesspackageautomaticrequestsettings?view=graph-rest-1.0)
configured. The following conditions cause the function to skip with a warning or error:

| Condition | Behavior |
|---|---|
| No auto-assignment policy found | Warning - skipped |
| Auto-assignment policy is inactive (`requestAccessForAllowedTargets = false`) | Warning - skipped |
| More than one active auto-assignment policy | Error - skipped (misconfiguration, [only one is supported](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-auto-assignment-policy)) |
| Active policy has no `membershipRule` (dummy/placeholder policy) | Warning - skipped |
| `membershipRule` evaluates to zero users | Warning - skipped (safety guard against unintended bulk removal) |

## Filter support

The module reads the `membershipRule` from the access package's auto-assignment policy and translates
it to a Graph OData filter. The following Entra attribute syntax is supported:

- Standard user properties: `user.department`, `user.jobTitle`, `user.country`, `user.companyName`, etc.
- Extension attributes 1-15: `user.extensionAttribute1` through `user.extensionAttribute15`
  (mapped to [`onPremisesExtensionAttributes`](https://learn.microsoft.com/en-us/graph/api/resources/onpremisesextensionattributes?view=graph-rest-1.0))
- Operators: `-eq`, `-ne`, `-and`, `-or`, parentheses for grouping, and `-match`/`-notMatch` with a plain `"^prefix"`

The translated filter is only a shortlist. Every user it disagrees with is confirmed with Entra's
`evaluateDynamicMembership`, and an unsupported operator stops the run rather than guessing.

Custom schema extensions (`extension_<guid>_*`) are not supported yet. If needed please open an issue.

## Development

```powershell
# Import locally
Import-Module ./EntraVacuum/EntraVacuum.psd1 -Force

# Lint
Invoke-ScriptAnalyzer -Path ./EntraVacuum -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Test
Invoke-Pester ./Tests

# Validate manifest before publishing
Test-ModuleManifest -Path ./EntraVacuum/EntraVacuum.psd1
```

### Compare access packages (read-only)

`tools/Compare-PackageMembership.ps1` explains why access packages with identical auto-assignment
rules end up with different members. It compares the auto-assignment policies (rule, removal/grace
settings, expiration) without paging every assignment, and can optionally show recent assignment
requests and check specific users. It only reads - nothing is assigned or removed.

```powershell
Connect-MgGraph -Scopes EntitlementManagement.Read.All, User.Read.All, GroupMember.Read.All

./tools/Compare-PackageMembership.ps1 -DisplayNameLike '*-region' -RecentDays 14 -UserPrincipalName user@contoso.com
```

## Versioning

Bump the version before merging changes that should be published:

```powershell
./Invoke-VersionBump.ps1           # patch: 0.1.0 -> 0.1.1
./Invoke-VersionBump.ps1 -Part Minor  # minor: 0.1.0 -> 0.2.0
./Invoke-VersionBump.ps1 -Part Major  # major: 0.1.0 -> 1.0.0
```

Then trigger a publish manually from the Actions tab once merged.

## License

MIT
