# Changelog

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
