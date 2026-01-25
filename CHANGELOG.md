# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2024-01-24

### Added
- Initial release
- `plugin :privacy` for Sequel models
- Policy definition DSL (`policies` method)
- Field-level privacy protection (`protect_field` method)
- ViewerContext system (ActorVC, AllPowerfulVC, APIVC)
- Policy evaluation engine with caching
- Built-in policies: AlwaysDeny, AlwaysAllow, PassAndLog
- PolicyDSL module for defining custom policies
