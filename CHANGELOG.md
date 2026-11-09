# Changelog

## [0.3.0] - 2026-11-09

### Added
- `Get-EntraVacAccessPackageDrift` reads every page of assignments and users (previously only the first page, so large packages were misreported)
- `Delivering` assignments count as assigned and are never added twice; new `Delivering` and `DeliveringNotInRule` output fields
- Every add/remove candidate is confirmed with Entra's `evaluateDynamicMembership` (requires Groups Administrator, Global Administrator or Intune Administrator). A failed call stops the run instead of reporting a partial result
- Grace period handling: assignments that no longer match but already have an expiry date are reported in `InGracePeriod` and left for Entra to remove. `-IncludeGracePeriod` overrides this
- A deleted user is treated as no longer matching the rule
- `Sync-EntraVacAccessPackage` now uses `Get-EntraVacAccessPackageDrift`, supports `-WhatIf`/`-Confirm`, and has a removal cap (`-MaxRemovals`, default 100) with `-Force` to override
- Filter translation supports `-notMatch "^prefix"` and `-match "^prefix"`; any other unsupported operator now throws instead of building a wrong filter
- New output fields: `AssignmentPolicyId`, `MembershipRule`, `GraphFilter`, `AssignmentsRead`, `TargetUsersRead`, `ExcludedByRule`, `InGracePeriod`
- `tools/Compare-PackageMembership.ps1` (read-only) compares auto-assignment policies across packages

### Changed
- `ShouldRemove`, `ShouldReprocess` and the delivering lists now return assignment objects (`.Id`, `.Target.ObjectId`, `.Target.DisplayName`) rather than target objects
- Still depends only on `Microsoft.Graph.Authentication`; no additional Graph SDK modules are required
- Tests rewritten and extended (29 Pester tests)


## [0.2.1] - 2026-05-26

### Fixed
- Removed `Microsoft.Graph.Identity.Governance` from `RequiredModules` — the module was never called (all Graph access uses `Invoke-MgGraphRequest`), but its presence triggered `GetScriptCmdlets` scanning on import, causing `OutOfMemoryException` in memory-constrained environments

## [0.2.0] - 2026-05-06

### Added
- `PartiallyDelivered` assignment state handling — reprocesses via `POST .../assignments/{id}/reprocess` instead of remove + re-add
- `extensionAttribute1`–`extensionAttribute15` filter support, mapped to `onPremisesExtensionAttributes` in the Graph OData filter
- `ConsistencyLevel: eventual` and `$count=true` headers on user queries — required for advanced filter properties
- Policy validation guards: inactive policy, more than one active policy, empty `membershipRule`, zero-user safety guard
- `ShouldReprocess` field on `Get-EntraVacAccessPackageDrift` output

### Changed
- `Get-EntraVacAccessPackageDrift` and `Sync-EntraVacAccessPackage` now query both `Delivered` and `PartiallyDelivered` assignments

## [0.1.0] - 2026-05-06

### Added
- `Sync-EntraVacAccessPackage` - reconciles access package assignments against auto-assignment policy filter
- `Get-EntraVacAccessPackageDrift` - reports drift without making changes
