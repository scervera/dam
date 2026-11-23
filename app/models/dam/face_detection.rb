# frozen_string_literal: true

module Dam
  class FaceDetection < ApplicationRecord
    self.table_name = "face_detections"

    belongs_to :asset, class_name: "Dam::Asset"
    belongs_to :tenant, class_name: Dam.tenant_class_name
    belongs_to :person, class_name: "Dam::FacePerson", optional: true, counter_cache: :face_count

    validates :asset_id, :tenant_id, presence: true
    # face_engine_id: Rekognition FaceId when using AWS Rekognition engine
    validates :bounding_box, presence: true

    before_validation :ensure_tenant_is_set

    # Bounding box is stored as JSON: { "x" => 0.0-1.0, "y" => 0.0-1.0, "width" => 0.0-1.0, "height" => 0.0-1.0 } (percentages)
    def bounding_box_x
      (bounding_box || {}).dig("x").to_f
    end

    def bounding_box_y
      (bounding_box || {}).dig("y").to_f
    end

    def bounding_box_width
      (bounding_box || {}).dig("width").to_f
    end

    def bounding_box_height
      (bounding_box || {}).dig("height").to_f
    end

    private

    def ensure_tenant_is_set
      return if tenant_id.present?
      self.tenant_id = asset&.tenant_id if asset.present?
    end
  end
end
