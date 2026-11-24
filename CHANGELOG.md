# Changelog

## 0.2.0 (2026-11-24)

**Breaking:** all tables are now prefixed `dam_` (`dam_assets`, `dam_tags`, `dam_groups`, …) so they don't collide with host tables. Models use the engine's default `dam_` prefix instead of explicit `table_name`s. Existing installs need a migration that renames the 16 tables (`rename_table :assets, :dam_assets`, and so on; Rails renames default-named indexes with them, and foreign keys follow). Columns and polymorphic types (`Dam::Asset`) are unchanged.

## 0.1.0 (2026-11-23)

First standalone release.

- JSON API for assets (uploads, thumbnails, previews, poster frames, derivatives and lineage, recycle bin, streaming), tags, collections, smart folders, groups, drop zones, watched folders, and face people/detections.
- Host integration through `Dam.config` (tenant/user classes, parent controller, current tenant/user, stream-token auth, storage, retention, serializers, AI request wrapper) and `ActiveSupport::Notifications` events (`asset_created.dam`, `asset_destroying.dam`, `ai_usage.dam`).
- `bin/rails generate dam:install` for the tables (PostgreSQL) and initializer.
- Optional OpenAI auto-tagging and AWS Rekognition face recognition.
