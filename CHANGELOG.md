# Changelog


## [Unreleased]

## [0.7.0] – 2026-08-26
- Removed `#for_vc` on `Sequel::Model` instances. Instead, call `#reset_viewer_context(vc, reason)`.
- Removed `#viewer_context=` from `Sequel::Model` instances.
- Added `#use(&block)` to Omniscient and AllPowerful viewer contexts. The block receives the viewer context and the reason it was created.

## [0.1.0]

### Added
- Initial release
- `plugin :privacy` for Sequel models
- Policy definition DSL (`policies` method)
- Field-level privacy protection (`protect_field` method)
- ViewerContext system (ActorVC, AllPowerfulVC, APIVC)
- Policy evaluation engine with caching
- Built-in policies: AlwaysDeny, AlwaysAllow, PassAndLog
- PolicyDSL module for defining custom policies
