module Dam
  class DropZoneFile < ApplicationRecord
    belongs_to :drop_zone, class_name: "Dam::DropZone"
    belongs_to :asset, class_name: "Dam::Asset"
    belongs_to :uploaded_by, class_name: Dam.user_class_name
    belongs_to :tenant, class_name: Dam.tenant_class_name

    validates :uploaded_at, presence: true
    validates :tenant_id, presence: true

    before_validation :ensure_tenant_is_set

    # JSON attributes
    serialize :metadata, coder: JSON

    scope :recent, -> { order(uploaded_at: :desc) }
    scope :by_drop_zone, ->(drop_zone) { where(drop_zone: drop_zone) }
    scope :by_uploader, ->(user) { where(uploaded_by: user) }

    def metadata_hash
      metadata || {}
    end

    def metadata_hash=(hash)
      self.metadata = hash.is_a?(Hash) ? hash : {}
    end

    def filename
      asset.filename
    end

    def file_size
      asset.byte_size
    end

    def content_type
      asset.content_type
    end

    def download_url
      Rails.application.routes.url_helpers.rails_blob_url(asset.file, host: Rails.application.config.action_mailer.default_url_options[:host])
    end

    def apply_preset_tags
      return if drop_zone.preset_tag_names.blank?

      begin
        drop_zone.preset_tag_names.each do |tag_name|
          tag = Dam::Tag.find_or_create_by(name: tag_name.strip, tenant: tenant) do |t|
            t.tenant = tenant
          end
          unless asset.tags.include?(tag)
            # Create AssetTag directly with tenant_id to avoid validation issues
            Dam::AssetTag.create!(
              asset: asset,
              tag: tag,
              tenant: tenant
            )
          end
        end
      rescue => e
        Rails.logger.error "DropZoneFile: Failed to apply preset tags: #{e.message}"
        Rails.logger.error "DropZoneFile: Backtrace: #{e.backtrace.first(5).join('\n')}"
        # Don't raise - allow the drop_zone_file to be saved even if tags fail
      end
    end

    # Use after_create_commit to run callbacks after transaction commits
    # This prevents rollback if callbacks fail
    after_create_commit :apply_preset_tags, :notify_drop_zone_subscribers

    private

    def ensure_tenant_is_set
      return if tenant_id.present?

      if Dam.current_tenant
        self.tenant = Dam.current_tenant
      elsif tenant_id.nil? && Dam.current_tenant&.id
        self.tenant_id = Dam.current_tenant.id
      end
    end

    def notify_drop_zone_subscribers
      drop_zone.notify_subscribers_of_new_file(self, uploaded_by)
    end
  end
end
