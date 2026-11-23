# DAM

A multi-tenant digital asset management engine for Rails. It adds a JSON API for:

- **Assets:** uploads with thumbnails, previews and video poster frames; image derivatives such as crops, with lineage; a recycle bin with retention; byte-range streaming.
- **Organizing:** tags, collections, smart folders (saved tag queries), groups and drop zones (shared upload areas).
- **Watched folders:** scan a directory on a schedule and import new files.
- **AI, optional:** OpenAI vision auto-tagging, and AWS Rekognition face detection and recognition (`person:Name` tags).

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
gem "dam", git: "https://github.com/scervera/dam.git", tag: "v0.1.0"
```

```bash
bundle install
bin/rails active_storage:install   # if you don't use Active Storage yet
bin/rails generate dam:install --tenant-table=tenants --user-table=users
bin/rails db:migrate
```

The generator adds a migration for the DAM's 16 tables and `config/initializers/dam.rb`. Then mount the API inside your API scope:

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
| `ai_request_wrapper`, `ai_retryable_errors` | Pass-through, none | Wraps OpenAI calls, e.g. for rate limiting |
| `face_collection_prefix` | `AWS_REKOGNITION_COLLECTION_ID` or `"dam-faces"` | Prefix of the per-tenant Rekognition collections |

## Events

The DAM publishes `ActiveSupport::Notifications` events for side effects your app may care about:

| Event | Payload | When |
|---|---|---|
| `asset_created.dam` | `asset:` | After an asset is created and committed, e.g. for usage metering |
| `asset_destroying.dam` | `asset:` | Before an asset row is deleted. Delete rows that reference it here; an exception aborts the delete |
| `ai_usage.dam` | `tenant:`, `input_tokens:`, `output_tokens:` | After each OpenAI request |

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

Watched folders are scanned by `Dam::WatchedFolderSchedulerJob`, which re-enqueues itself every 30 seconds. Start it once, for example from an initializer: `Dam::WatchedFolderSchedulerJob.perform_later unless Dam::WatchedFolderSchedulerJob.scheduler_pending?`.

## Environment variables

| Variable | Purpose |
|---|---|
| `ACTIVE_STORAGE_HOST` | Host used in file URLs (default `http://localhost:8081`) |
| `DAM_MAX_FILE_SIZE_GB` | Upload size limit |
| `DAM_ASSET_LIST_CACHE_TTL_SECONDS` | Cache lifetime for asset list responses |
| `DAM_AI_AUTO_TAG_ENABLED`, `DAM_AI_AUTO_TAG_MAX_TAGS` | OpenAI auto-tagging of images |
| `OPENAI_API_KEY`, `OPENAI_VISION_MODEL`, `OPENAI_TEMPERATURE` | OpenAI client |
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
