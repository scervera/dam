# frozen_string_literal: true

require "aws-sdk-rekognition"

module Dam
  module Ai
    class FaceMatchingService
      DEFAULT_MATCH_THRESHOLD = 0.85
      DEFAULT_SUGGEST_THRESHOLD = 0.60
      MAX_CANDIDATES = 10

      attr_reader :face_detection, :tenant_id

      # @param face_detection [Dam::FaceDetection] detection with face_engine_id set (Rekognition)
      # @param tenant_id [Integer] optional, defaults to face_detection.tenant_id
      def initialize(face_detection:, tenant_id: nil)
        @face_detection = face_detection
        @tenant_id = tenant_id || face_detection.tenant_id
      end

      # Returns array of hashes: { person: Dam::FacePerson, confidence: Float }
      # Sorted by confidence descending.
      def call
        return [] unless face_detection.face_engine_id.present?
        return [] unless face_detection_enabled?

        collection_id = rekognition_collection_id
        response = rekognition_client.search_faces(
          collection_id: collection_id,
          face_id: face_detection.face_engine_id,
          max_faces: MAX_CANDIDATES,
          face_match_threshold: (match_threshold * 100).to_i
        )

        face_ids = Array(response.face_matches).map { |m| m.face&.face_id }.compact
        return [] if face_ids.empty?

        # Map Rekognition face_id -> our FaceDetection with person_id
        detections_with_person = Dam::FaceDetection
          .where(tenant_id: tenant_id, face_engine_id: face_ids)
          .where.not(person_id: nil)
          .includes(:person)

        # Build results with similarity from response (0-100 -> 0.0-1.0)
        match_by_face_id = response.face_matches.index_by { |m| m.face&.face_id }
        detections_with_person.filter_map do |det|
          match = match_by_face_id[det.face_engine_id]
          similarity = match&.similarity&.to_f
          next unless similarity
          confidence = (similarity / 100.0).round(4)
          { person: det.person, confidence: confidence }
        end.uniq { |h| h[:person].id }.sort_by { |h| -h[:confidence] }
      rescue Aws::Rekognition::Errors::ResourceNotFoundException
        []
      rescue Aws::Rekognition::Errors::ServiceError => e
        Rails.logger.error "Dam::Ai::FaceMatchingService Rekognition error: #{e.message}"
        []
      end

      def match_threshold
        (ENV.fetch("DAM_FACE_MATCH_THRESHOLD", DEFAULT_MATCH_THRESHOLD.to_s).to_f).clamp(0.0, 1.0)
      end

      def suggest_threshold
        (ENV.fetch("DAM_FACE_SUGGEST_THRESHOLD", DEFAULT_SUGGEST_THRESHOLD.to_s).to_f).clamp(0.0, 1.0)
      end

      private

      def face_detection_enabled?
        Dam.face_detection_enabled?
      end

      def rekognition_collection_id
        prefix = Dam.config.face_collection_prefix.call
        "#{prefix}-tenant-#{tenant_id}"
      end

      def rekognition_client
        opts = { region: ENV.fetch("AWS_REGION", "us-east-1") }
        if ENV["AWS_ACCESS_KEY_ID"].present? && ENV["AWS_SECRET_ACCESS_KEY"].present?
          opts[:credentials] = Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"])
        end
        @rekognition_client ||= Aws::Rekognition::Client.new(opts)
      end
    end
  end
end
