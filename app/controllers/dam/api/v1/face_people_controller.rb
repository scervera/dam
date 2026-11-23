# frozen_string_literal: true

module Dam::Api
  module V1
    class FacePeopleController < BaseController
      before_action :set_face_person, only: [ :show, :update, :destroy ]

      def index
        people = tenant_scope(Dam::FacePerson).order(:name)
        people = people.where("name ILIKE ?", "%#{params[:q]}%") if params[:q].present?
        people = people.limit(params[:limit] || 100)
        render_success({
          data: people.map { |p| face_person_json(p) }
        })
      end

      def show
        authorize_face_person(@face_person)
        render_success(face_person_json(@face_person))
      end

      def create
        person = Dam::FacePerson.new(face_person_params)
        person.tenant = Dam.current_tenant
        if person.save
          render_success(face_person_json(person), :created)
        else
          render_error(person.errors.full_messages.join(", "), :unprocessable_entity)
        end
      end

      def update
        authorize_face_person(@face_person)
        if @face_person.update(face_person_params)
          render_success(face_person_json(@face_person))
        else
          render_error(@face_person.errors.full_messages.join(", "), :unprocessable_entity)
        end
      end

      def destroy
        authorize_face_person(@face_person)
        @face_person.destroy
        head :no_content
      end

      private

      def set_face_person
        @face_person = tenant_scope(Dam::FacePerson).find(params[:id])
      end

      def authorize_face_person(record)
        # Same permission as tagging assets
        return if current_user.admin? || current_user.tenant_owner? || current_user.dam_writer?
        render_error("Not allowed", :forbidden)
      end

      def face_person_params
        params.permit(:name, :thumbnail_asset_id)
      end

      def face_person_json(person)
        {
          id: person.id,
          name: person.name,
          face_count: person.face_count,
          thumbnail_asset_id: person.thumbnail_asset_id,
          created_at: person.created_at,
          updated_at: person.updated_at
        }
      end
    end
  end
end
