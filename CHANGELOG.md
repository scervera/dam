# Changelog

## 0.3.1

### Fixed
- Drop zones: `GET /drop_zones/:id` and `/drop_zones/:id/files` no longer call a `download_url` route the host had to define; file URLs come from `Dam::AssetUrls` (stream and thumbnail).
- Watched folders: `create` sets the current tenant (it always failed with "Tenant must exist").
- Watched folders: `scan_history` returns the list of scans (the block was attached to `render`).
- Tags: deleting a tag as a non-admin writer queried the old `tags` table.
- Asset lists: the first change in a tenant after a cache reset didn't invalidate the cached list (a missing version and the first bump both read as 1), so new uploads stayed hidden until `DAM_ASSET_LIST_CACHE_TTL_SECONDS` passed.

### Security
- Watched folders are managed by tenant owners and admins only; before, any signed-in user could create, scan or delete one for any server path.
- New `Dam.config.watched_folder_roots`: when set, watched-folder paths must resolve (including `..` and symlinks) inside one of these directories.

## 0.3.0 (unreleased)

**AI auto-tagging is provider-neutral.** It supports OpenAI, Anthropic Claude, and OpenAI-compatible servers (Ollama, vLLM, LM Studio, OpenRouter), chosen with `DAM_AI_PROVIDER`, `DAM_AI_MODEL`, `DAM_AI_API_KEY` and `DAM_AI_BASE_URL`, or `config.ai_provider` for a custom adapter. Existing installs that only set `OPENAI_API_KEY` keep using OpenAI.

- **Breaking:** `ruby-openai` is no longer a dependency. Add `gem "ruby-openai"` (OpenAI and compatible servers) or `gem "anthropic"` (Claude) to your Gemfile.
- **Breaking:** `Dam::Ai::Client` is replaced by `Dam::Ai::Providers` (`Base`, `OpenAi`, `Anthropic`).
- Auto-tagging is only enqueued, and `POST /assets/:id/auto_tag` only accepted (otherwise 422), when a provider is configured. Before, uploads without an OpenAI key queued jobs that failed.
- A refused or unsupported image is recorded in `ai_tagging_error` without retrying the job.
- `ai_usage.dam` events also carry `provider:` and `model:`.
- New `Dam.ai_tagging_enabled?` and `Dam.face_detection_enabled?`.
- New `config.queue_names` sets the Active Job queue per job kind. **Breaking:** `Dam::PurgeAssetJob` now uses `:default` instead of `:backup_replication`; set `config.queue_names = { purge: :backup_replication }` to keep the old queue.
- New `config.watched_folder_scheduler`: `:self_enqueue` (default, as before) or `:external`, for apps that schedule `Dam::WatchedFolderSchedulerJob` themselves (e.g. Solid Queue recurring tasks).

## 0.2.0 (2026-11-24)

**Breaking:** all tables are now prefixed `dam_` (`dam_assets`, `dam_tags`, `dam_groups`, …) so they don't collide with host tables. Models use the engine's default `dam_` prefix instead of explicit `table_name`s. Existing installs need a migration that renames the 16 tables (`rename_table :assets, :dam_assets`, and so on; Rails renames default-named indexes with them, and foreign keys follow). Columns and polymorphic types (`Dam::Asset`) are unchanged.

## 0.1.0 (2026-11-23)

First standalone release.

- JSON API for assets (uploads, thumbnails, previews, poster frames, derivatives and lineage, recycle bin, streaming), tags, collections, smart folders, groups, drop zones, watched folders, and face people/detections.
- Host integration through `Dam.config` (tenant/user classes, parent controller, current tenant/user, stream-token auth, storage, retention, serializers, AI request wrapper) and `ActiveSupport::Notifications` events (`asset_created.dam`, `asset_destroying.dam`, `ai_usage.dam`).
- `bin/rails generate dam:install` for the tables (PostgreSQL) and initializer.
- Optional OpenAI auto-tagging and AWS Rekognition face recognition.
