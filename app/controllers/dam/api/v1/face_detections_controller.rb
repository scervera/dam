# frozen_string_literal: true

module Dam::Api
  module V1
    class FaceDetectionsController < BaseController
      before_action :set_face_detection, only: [ :identify ]

      def identify
        authorize @face_detection.asset, :tag?
        person_id = params[:person_id]
        render_error("person_id is required", :unprocessable_entity) and return unless person_id.present?
        person = tenant_scope(Dam::FacePerson).find(person_id)
        @face_detection.update!(person: person)
        # Optionally add person name as a tag for searchability
        tag_name = "person:#{person.name}"
        @face_detection.asset.add_tag(tag_name) unless @face_detection.asset.tag_names.include?(tag_name)
        render_success({
          id: @face_detection.id,
          person_id: @face_detection.person_id,
          person_name: @face_detection.person.name
        })
      rescue ActiveRecord::RecordNotFound
        render_error("Face detection or person not found", :not_found)
      rescue StandardError => e
        Rails.logger.error "Face detection identify failed: #{e.message}"
        render_error(e.message, :unprocessable_entity)
      end

      private

      def set_face_detection
        @face_detection = Dam::FaceDetection.find(params[:id])
        unless @face_detection.tenant_id == Dam.current_tenant.id
          render_error("Face detection not found", :not_found)
          nil
        end
      rescue ActiveRecord::RecordNotFound
        render_error("Face detection not found", :not_found)
        nil
      end
    end
  end
end
