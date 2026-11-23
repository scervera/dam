# frozen_string_literal: true

module Dam
  module Ai
    class AutoTaggingService
      TAG_NAME_FORMAT = /\A[a-zA-Z0-9\s\-_]+\z/
      MIN_TAG_LENGTH = 2
      MAX_TAG_LENGTH = 50

      attr_reader :asset

      def initialize(asset:)
        @asset = asset
      end

      def call
        return false unless ai_auto_tag_enabled?
        return false unless asset.image?
        return false unless asset.file.attached?

        existing_tag_names = tenant_tag_names
        image_data_url = build_image_data_url
        return false if image_data_url.blank?

        prompt = build_prompt(existing_tag_names)
        messages = [
          {
            role: "user",
            content: [
              { type: "text", text: prompt },
              { type: "image_url", image_url: { url: image_data_url, detail: "low" } }
            ]
          }
        ]

        response = client.chat_completion(
          messages: messages,
          max_tokens: 512
        )

        tag_names = parse_and_validate_tags(response, existing_tag_names)
        return false if tag_names.empty?

        apply_tags(tag_names)
        asset.update_columns(ai_auto_tagged_at: Time.current, ai_tagging_error: nil)
        true
      rescue StandardError => e
        Rails.logger.error "Dam::Ai::AutoTaggingService failed for asset #{asset.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        asset.update_columns(ai_tagging_error: e.message.truncate(500))
        raise
      end

      private

      def client
        @client ||= Dam::Ai::Client.new
      end

      def ai_auto_tag_enabled?
        ENV.fetch("DAM_AI_AUTO_TAG_ENABLED", "true").to_s.downcase.in?(%w[true 1 yes])
      end

      def max_tags
        ENV.fetch("DAM_AI_AUTO_TAG_MAX_TAGS", "10").to_i.clamp(1, 20)
      end

      def tenant_tag_names
        Dam::Tag.where(tenant_id: asset.tenant_id).pluck(:name)
      end

      def build_image_data_url
        # Use preview if available (smaller); otherwise use main file
        attachment = asset.preview.attached? ? asset.preview : asset.file
        return nil unless attachment&.attached?

        blob = attachment.blob
        data = blob.download
        mime = blob.content_type.presence || "image/jpeg"
        base64 = Base64.strict_encode64(data)
        "data:#{mime};base64,#{base64}"
      end

      def build_prompt(existing_tag_names)
        existing_list = existing_tag_names.any? ? existing_tag_names.join(", ") : "(none yet)"
        <<~PROMPT
          Analyze this image and suggest tags for a digital asset library.

          Existing tags for this library (prefer these when they apply): #{existing_list}

          Return a JSON object with exactly two arrays of strings:
          - "existing_tags": tags from the list above that apply to this image (use the exact names).
          - "new_tags": short descriptive tags not in the list (e.g. subject, style, setting). Use lowercase, 2-50 characters, only letters, numbers, spaces, hyphens, underscores.

          Limit total tags to #{max_tags}. Return only valid JSON, no other text.
        PROMPT
      end

      def parse_and_validate_tags(response, existing_tag_names)
        content = response.dig("choices", 0, "message", "content")
        return [] if content.blank?

        parsed = JSON.parse(content)
        existing = Array(parsed["existing_tags"]).map { |s| s.to_s.strip }.reject(&:blank?)
        new_tags = Array(parsed["new_tags"]).map { |s| sanitize_tag_name(s.to_s) }.reject(&:blank?)

        combined = (existing + new_tags).uniq
        combined = combined.select { |name| existing_tag_names.include?(name) || valid_tag_name?(name) }
        combined.first(max_tags)
      end

      def sanitize_tag_name(raw)
        return nil if raw.blank?
        s = raw.strip
        s = s.gsub(/[^a-zA-Z0-9\s\-_]/, "").strip
        s = s[0, MAX_TAG_LENGTH] if s.length > MAX_TAG_LENGTH
        s.length >= MIN_TAG_LENGTH ? s : nil
      end

      def valid_tag_name?(name)
        return false if name.length < MIN_TAG_LENGTH || name.length > MAX_TAG_LENGTH
        name.match?(TAG_NAME_FORMAT)
      end

      def apply_tags(tag_names)
        tag_names.each { |name| asset.add_tag(name) }
      end
    end
  end
end
