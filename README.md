# DAM

A multi-tenant digital asset management engine for Rails. It adds a JSON API for:

- **Assets:** uploads with thumbnails, previews and video poster frames; image derivatives such as crops, with lineage; a recycle bin with retention; byte-range streaming.
- **Organizing:** tags, collections, smart folders (saved tag queries), groups and drop zones (shared upload areas).
- **Watched folders:** scan a directory on a schedule and import new files.
- **AI, optional:** image auto-tagging with OpenAI, Anthropic Claude or any OpenAI-compatible server (Ollama, vLLM, LM Studio, OpenRouter), and AWS Rekognition face detection and recognition (`person:Name` tags).

Your application keeps its own tenants, users, authentication and storage. The engine plugs into them through `Dam.config`.

**License:** [PolyForm Noncommercial 1.0.0](LICENSE.md). This is a *source-available* license, not an OSI open-source license: you may use, modify and share the engine for noncommercial purposes. Commercial use requires a separate license from Cervera Ventures LLC.

## Requirements

- Ruby 3.2+ and Rails 8.0+
- PostgreSQL (the tables use `jsonb`)
- Active Storage, configured in your app
- System tools: [libvips](https://www.libvips.org/) for image processing, `ffmpeg` for video thumbnails and poster frames, and `exiftool` for metadata. On Ubuntu: `apt-get install libvips libimage-exiftool-perl ffmpeg`.
- Background jobs through Active Job (any adapter)

## Installation

The gem is distributed from GitHub, not RubyGems (a different gem named `dam` may exist there):

```ruby
# Gemfile
gem "dam", git: "https://github.com/scervera/dam.git", tag: "v0.3.2"
```

```bash
bundle install
bin/rails active_storage:install   # if you don't use Active Storage yet
bin/rails generate dam:install --tenant-table=tenants --user-table=users
bin/rails db:migrate
```

The generator adds a migration for the DAM's 16 tables (all prefixed `dam_`, e.g. `dam_assets`, `dam_tags`) and `config/initializers/dam.rb`. Then mount the API inside your API scope:

```ruby
# config/routes.rb
scope "api/v1" do
  mount Dam::Engine, at: "/"
end
```

The endpoints are now served at `/api/v1/assets`, `/api/v1/tags` and so on.

## What your app provides

### An API base controller

`config.parent_controller` names it. The DAM's controllers inherit from it, so it must provide:

| Method | Purpose |
|---|---|
| `authenticate_user!` | A `before_action` that rejects unauthenticated requests |
| `current_user` | The signed-in user |
| `tenant_scope(relation)` | Limits a relation to the current tenant, e.g. `relation.where(tenant: Dam.current_tenant)` |
| `render_success(data, status = :ok)` | Renders a JSON response |
| `render_error(message, status)` | Renders a JSON error |

It should also handle `Pundit::NotAuthorizedError`, for example by rendering a 403. The DAM authorizes with its own [Pundit](https://github.com/varvet/pundit) policies.

### A user model

| Method | Used for |
|---|---|
| `admin?`, `tenant_owner?`, `dam_writer?` | Permissions. Admins, owners and writers can create and change content; anyone signed in can view |
| `disabled?`, `email`, `tenant` | Account checks and display. `tenant` is only needed by the default `tenant_for_request` |
| `assets`, `collections`, `smart_folders` | `has_many` to `Dam::Asset`, `Dam::Collection` and `Dam::SmartFolder` (`user_id`) |
| `owned_groups`, `owned_drop_zones` | `has_many` to `Dam::Group` and `Dam::DropZone` (`owner_id`) |
| `subscribed_drop_zones` | `has_many :subscribed_drop_zones, through: :drop_zone_subscriptions` (`Dam::DropZoneSubscription`) |

### A tenant model

It needs `users` (used by the default `find_tenant_user` and `import_user_for`) and `name`. The DAM's tables reference it through `tenant_id`.

`spec/dummy` is a complete minimal host app; see its `User`, `Tenant` and `ApplicationController`.

## Configuration

Set these in `config/initializers/dam.rb`. Every setting is documented in [`lib/dam/configuration.rb`](lib/dam/configuration.rb).

```ruby
Dam.configure do |config|
  config.tenant_class = "Tenant"
  config.user_class = "User"
  config.parent_controller = "Api::BaseController"

  # Where the current tenant and user live (default: Dam::Current).
  config.current_tenant = -> { Current.tenant }
  config.set_current_tenant = ->(tenant) { Current.tenant = tenant }
  config.current_user = -> { Current.user }
  config.set_current_user = ->(user) { Current.user = user }

  # GET /assets/:id/stream takes ?token=, because <video> elements can't send headers.
  config.authenticate_token = ->(token) { User.find_by_api_token(token) }
  config.tenant_for_request = ->(user, request) { user.tenant }

  config.soft_delete_enabled = -> { true }    # recycle bin instead of immediate deletion
  config.asset_retention_days = -> { 30 }
end
```

Other settings:

| Setting | Default | Purpose |
|---|---|---|
| `find_tenant_user` | `tenant.users.find(id)` | Finds a tenant's user, e.g. when adding group members |
| `import_user_for` | `tenant.users.first` | Who owns files a watched folder imports |
| `storage_service_for` | `nil` (default service) | Active Storage service for generated files |
| `serialize_user`, `serialize_tenant` | `{ id: }` | How an asset's user and tenant appear in responses |
| `ai_provider` | `nil` (from ENV) | AI auto-tagging provider; see [AI auto-tagging](#ai-auto-tagging) |
| `ai_request_wrapper`, `ai_retryable_errors` | Pass-through, none | Wraps every AI request, e.g. for rate limiting; errors listed are retried |
| `queue_names` | `:default` for all | Active Job queue per job kind: `default`, `ai`, `purge`, `scheduler`. Set only the ones you change |
| `watched_folder_roots` | `nil` (any path) | Directories watched folders may point into, e.g. `[ "/watched" ]` |
| `watched_folder_keep_originals` | `false` | `true` leaves imported files in the watched folder (read-only archives); `false` moves them into the DAM |
| `watched_folder_scheduler` | `:self_enqueue` | How `Dam::WatchedFolderSchedulerJob` repeats; see below |
| `face_collection_prefix` | `AWS_REKOGNITION_COLLECTION_ID` or `"dam-faces"` | Prefix of the per-tenant Rekognition collections |

## Events

The DAM publishes `ActiveSupport::Notifications` events for side effects your app may care about:

| Event | Payload | When |
|---|---|---|
| `asset_created.dam` | `asset:` | After an asset is created and committed, e.g. for usage metering |
| `asset_destroying.dam` | `asset:` | Before an asset row is deleted. Delete rows that reference it here; an exception aborts the delete |
| `ai_usage.dam` | `tenant:`, `input_tokens:`, `output_tokens:`, `provider:`, `model:` | After each AI request |

```ruby
ActiveSupport::Notifications.subscribe("asset_destroying.dam") do |event|
  Transcript.where(asset_id: event.payload[:asset].id).delete_all
end
```

## API

All endpoints are relative to the mount point.

| Resource | Endpoints |
|---|---|
| Assets | `GET/POST /assets`; `GET/PATCH/DELETE /assets/:id`; `GET /assets/search`, `/assets/recycle_bin`; `POST /assets/:id/restore`, `DELETE /assets/:id/purge`; `POST /assets/:id/add_tag`, `DELETE /assets/:id/remove_tag`; `POST /assets/:id/derivatives`, `GET /assets/:id/lineage`; `POST /assets/:id/generate_poster_frame`; `GET /assets/:id/stream`; `POST /assets/:id/auto_tag`, `/detect_faces`, `GET /assets/:id/faces` |
| Tags | `GET/POST /tags`, `GET/PATCH/DELETE /tags/:id`, `GET /tags/popular`, `/tags/search` |
| Collections | `/collections` (CRUD), `POST /collections/:id/add_asset`, `DELETE /collections/:id/remove_asset`, `GET /collections/public_collections` |
| Smart folders | `/smart_folders` (CRUD), `GET /smart_folders/:id/assets`, `POST /smart_folders/:id/pin`, `/unpin`, `GET /smart_folders/sidebar` |
| Groups | `/groups` (CRUD), `POST /groups/:id/add_member`, `DELETE /groups/:id/remove_member` |
| Drop zones | `/drop_zones` (CRUD), `POST /drop_zones/:id/subscribe`, `DELETE /drop_zones/:id/unsubscribe`, `GET /drop_zones/:id/files`, `POST /drop_zones/:id/upload` |
| Watched folders | `/watched_folders` (CRUD), `POST /watched_folders/:id/scan_now`, `GET /watched_folders/:id/scan_history`, `/notifications` |
| Faces | `/face_people` (CRUD), `PUT /face_detections/:id/identify` |

Watched folders are scanned by `Dam::WatchedFolderSchedulerJob`. It runs in one of two modes (`config.watched_folder_scheduler`):

- `:self_enqueue` (default): each run enqueues the next one 30 seconds later. Start it once, for example from an initializer: `Dam::WatchedFolderSchedulerJob.perform_later unless Dam::WatchedFolderSchedulerJob.scheduler_pending?`. (`scheduler_pending?` can only see Sidekiq queues; with other adapters it returns `false`.)
- `:external`: each run is a single pass and your app schedules it, for example with a Solid Queue recurring task in `config/recurring.yml`:

  ```yaml
  production:
    dam_watched_folders:
      class: Dam::WatchedFolderSchedulerJob
      schedule: every 30 seconds
  ```

## AI auto-tagging

New images are sent to a vision model, which suggests tags (preferring the tenant's existing tags). Tagging is off until a provider is configured. Configure it with environment variables:

| Provider | `DAM_AI_PROVIDER` | Gem to add | Key | Model (`DAM_AI_MODEL`) |
|---|---|---|---|---|
| OpenAI | `openai` | `ruby-openai` | `DAM_AI_API_KEY` or `OPENAI_API_KEY` | default `gpt-4o` (or `OPENAI_VISION_MODEL`) |
| Anthropic Claude | `anthropic` | `anthropic` | `DAM_AI_API_KEY` or `ANTHROPIC_API_KEY` | default `claude-opus-5-5`; `claude-haiku-5-5` costs much less for large libraries |
| OpenAI-compatible | `openai_compatible` | `ruby-openai` | optional | required, e.g. `llava` |

- `DAM_AI_BASE_URL` points at the server for `openai_compatible` (required, e.g. `http://ollama:11434/v1`), and can route the others through a proxy.
- When `DAM_AI_PROVIDER` is unset and `OPENAI_API_KEY` is set, OpenAI is used, as before 0.3.
- `DAM_AI_AUTO_TAG_ENABLED=false` turns tagging off; `DAM_AI_AUTO_TAG_MAX_TAGS` (default 10) caps tags per image.
- `Dam.ai_tagging_enabled?` and `Dam.face_detection_enabled?` tell your app whether to show the AI features.

The provider SDKs are not dependencies of this gem: add the gem for the provider you use. With Claude, replies are constrained to the tag JSON schema (structured outputs), and declined requests use the API's server-side fallback model.

To use another provider, set `config.ai_provider` to an object with the same method as `Dam::Ai::Providers::Base#analyze_image(prompt:, image_bytes:, mime:, schema:, max_tokens:)`, returning a `Dam::Ai::Providers::Base::Result`. Subclassing `Base` gives you the retries, request wrapper and usage event.

## Environment variables

| Variable | Purpose |
|---|---|
| `ACTIVE_STORAGE_HOST` | Host used in file URLs (default `http://localhost:8081`) |
| `DAM_MAX_FILE_SIZE_GB` | Upload size limit |
| `DAM_ASSET_LIST_CACHE_TTL_SECONDS` | Cache lifetime for asset list responses |
| `DAM_AI_PROVIDER`, `DAM_AI_MODEL`, `DAM_AI_API_KEY`, `DAM_AI_BASE_URL` | AI auto-tagging provider ([details](#ai-auto-tagging)) |
| `DAM_AI_AUTO_TAG_ENABLED`, `DAM_AI_AUTO_TAG_MAX_TAGS` | Turn auto-tagging off; tags per image |
| `OPENAI_API_KEY`, `OPENAI_VISION_MODEL`, `OPENAI_TEMPERATURE` | OpenAI fallbacks and sampling temperature |
| `ANTHROPIC_API_KEY` | Anthropic fallback key |
| `DAM_FACE_DETECTION_ENABLED`, `DAM_FACE_DETECTION_ENGINE` | Face detection (engine: `rekognition`) |
| `DAM_FACE_MATCH_THRESHOLD`, `DAM_FACE_SUGGEST_THRESHOLD` | Face recognition confidence thresholds |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_REKOGNITION_COLLECTION_ID` | AWS Rekognition |
| `ASSET_UPLOAD_VERBOSE_LOGGING` | Extra upload logging when `true` |

## Development

The specs run against `spec/dummy`, a minimal host app with its own `Tenant` and `User` models:

```bash
bundle install
bin/rails db:create db:schema:load   # RAILS_ENV=test; set DATABASE_URL if needed
bundle exec rspec
```

`spec/live` calls the real AI APIs and is skipped unless `DAM_LIVE_AI=1` (with `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and/or `DAM_LIVE_OPENAI_COMPATIBLE_URL` set).
