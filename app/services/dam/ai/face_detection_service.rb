# frozen_string_literal: true

require "aws-sdk-rekognition"

module Dam
  module Ai
    class FaceDetectionService
      attr_reader :asset

      def initialize(asset:)
        @asset = asset
      end

      def call
        unless face_detection_enabled?
          Rails.logger.info "Dam::Ai::FaceDetectionService: Skipping asset #{asset.id} - DAM_FACE_DETECTION_ENABLED is not true"
          return []
        end
        unless asset.image?
          Rails.logger.info "Dam::Ai::FaceDetectionService: Skipping asset #{asset.id} - not an image"
          return []
        end
        unless asset.file.attached?
          Rails.logger.info "Dam::Ai::FaceDetectionService: Skipping asset #{asset.id} - no file attached"
          return []
        end

        # Use compressed variant for Rekognition: thumbnail (smallest) or preview, then full file only if under 15MB
        image_bytes, source = fetch_image_bytes_for_rekognition
        if image_bytes.blank?
          Rails.logger.warn "Dam::Ai::FaceDetectionService: Skipping asset #{asset.id} - no image under Rekognition limit (15MB)"
          return []
        end

        Rails.logger.info "Dam::Ai::FaceDetectionService: Using #{source} for asset #{asset.id} (#{image_bytes.bytesize} bytes)"
        collection_id = rekognition_collection_id
        Rails.logger.info "Dam::Ai::FaceDetectionService: Calling Rekognition for asset #{asset.id} (collection=#{collection_id})"
        ensure_collection_exists!(collection_id)

        response = rekognition_client.index_faces(
          collection_id: collection_id,
          image: { bytes: image_bytes },
          external_image_id: "asset_#{asset.id}",
          max_faces: 100,
          quality_filter: "AUTO"
        )

        # Remove existing detections for this asset (re-run detection replaces all)
        asset.face_detections.destroy_all

        detected_at = Time.current
        records = []

        Array(response.face_records).each do |face_record|
          face = face_record.face
          next unless face

          box = face.bounding_box
          next unless box

          bounding_box = {
            "x" => box.left.to_f,
            "y" => box.top.to_f,
            "width" => box.width.to_f,
            "height" => box.height.to_f
          }

          detection = asset.face_detections.create!(
            tenant_id: asset.tenant_id,
            bounding_box: bounding_box,
            face_engine_id: face.face_id,
            confidence: face.confidence.to_f,
            detected_at: detected_at
          )
          records << detection
        end

        Rails.logger.info "Dam::Ai::FaceDetectionService: Rekognition IndexFaces returned #{records.size} face(s) for asset #{asset.id}"
        apply_auto_recognition(records) if records.any?
        records
      rescue Aws::Rekognition::Errors::RequestEntityTooLarge => e
        Rails.logger.warn "Dam::Ai::FaceDetectionService: Skipping asset #{asset.id} - image too large for Rekognition: #{e.message}"
        [] # Do not re-raise so the job completes and does not retry
      rescue Aws::Rekognition::Errors::ServiceError => e
        Rails.logger.error "Dam::Ai::FaceDetectionService Rekognition error for asset #{asset.id}: #{e.message}"
        raise
      end

      private

      def face_detection_enabled?
        Dam.face_detection_enabled?
      end

      def face_detection_engine
        ENV.fetch("DAM_FACE_DETECTION_ENGINE", "rekognition").to_s.downcase
      end

      def rekognition_collection_id
        prefix = Dam.config.face_collection_prefix.call
        "#{prefix}-tenant-#{asset.tenant_id}"
      end

      def ensure_collection_exists!(collection_id)
        rekognition_client.create_collection(collection_id: collection_id)
      rescue Aws::Rekognition::Errors::ResourceAlreadyExistsException
        # Collection already exists
      end

      def rekognition_client
        opts = { region: ENV.fetch("AWS_REGION", "us-east-1") }
        if ENV["AWS_ACCESS_KEY_ID"].present? && ENV["AWS_SECRET_ACCESS_KEY"].present?
          opts[:credentials] = Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"])
        end
        @rekognition_client ||= Aws::Rekognition::Client.new(opts)
      end

      # Rekognition accepts max 15MB. Prefer thumbnail (200x200), then preview (1920x1920), then file if small enough.
      def fetch_image_bytes_for_rekognition
        max_bytes = 15 * 1024 * 1024 # 15MB
        [
          [ asset.thumbnail, "thumbnail" ],
          [ asset.preview, "preview" ],
          [ asset.file, "file" ]
        ].each do |attachment, label|
          next unless attachment.attached?
          blob = attachment.blob
          next if blob.byte_size > max_bytes
          data = blob.download
          return [ data, label ] if data.present?
        end
        [ nil, nil ]
      end

      def apply_auto_recognition(detections)
        match_threshold = (ENV.fetch("DAM_FACE_MATCH_THRESHOLD", "0.85").to_f).clamp(0.0, 1.0)
        detections.each do |detection|
          matches = Dam::Ai::FaceMatchingService.new(face_detection: detection).call
          next if matches.empty?

          best = matches.first
          next if best[:confidence] < match_threshold

          person = best[:person]
          detection.update!(person: person)
          tag_name = "person:#{person.name}"
          asset.add_tag(tag_name) unless asset.tag_names.include?(tag_name)
        end
      end
    end
  end
end
