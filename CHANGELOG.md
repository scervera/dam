# Changelog

## 0.1.0 (2026-11-23)

First standalone release.

- JSON API for assets (uploads, thumbnails, previews, poster frames, derivatives and lineage, recycle bin, streaming), tags, collections, smart folders, groups, drop zones, watched folders, and face people/detections.
- Host integration through `Dam.config` (tenant/user classes, parent controller, current tenant/user, stream-token auth, storage, retention, serializers, AI request wrapper) and `ActiveSupport::Notifications` events (`asset_created.dam`, `asset_destroying.dam`, `ai_usage.dam`).
- `bin/rails generate dam:install` for the tables (PostgreSQL) and initializer.
- Optional OpenAI auto-tagging and AWS Rekognition face recognition.
