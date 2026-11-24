# frozen_string_literal: true

module Dam
  class FacePerson < ApplicationRecord
    belongs_to :tenant, class_name: Dam.tenant_class_name
    belongs_to :thumbnail_asset, class_name: "Dam::Asset", optional: true
    has_many :face_detections, class_name: "Dam::FaceDetection", dependent: :nullify

    validates :name, presence: true, length: { minimum: 1, maximum: 255 }
    validates :name, uniqueness: { scope: :tenant_id }
    validates :tenant_id, presence: true
  end
end
