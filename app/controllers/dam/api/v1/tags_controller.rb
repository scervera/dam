module Dam::Api
  module V1
    class TagsController < BaseController
      def index
        @tags = tenant_scope(Dam::Tag).includes(:assets).alphabetical
        @tags = @tags.page(params[:page]).per(params[:per_page] || 50)

        # Serialize each tag individually
        serialized_tags = @tags.map do |tag|
          begin
            hash = Dam::TagSerializer.flat(tag)
            # Serializers' .flat returns the attribute hash directly
            # Check if it's wrapped in :data or return hash directly
            result = hash.is_a?(Hash) ? (hash[:data] || hash) : hash
            # Return the result if it's a valid hash (even if id is missing, let frontend handle it)
            result.is_a?(Hash) ? result : nil
          rescue => e
            Rails.logger.error "Error serializing tag #{tag.id}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            nil
          end
        end.compact

        render_success({
          data: serialized_tags,
          meta: {
            current_page: @tags.current_page,
            total_pages: @tags.total_pages,
            total_count: @tags.total_count,
            per_page: @tags.limit_value
          }
        })
      end

      def show
        @tag = tenant_scope(Dam::Tag).find_by(name: params[:id]) || tenant_scope(Dam::Tag).find(params[:id])
        @assets = @tag.assets.not_deleted.includes(:user, :tags).page(params[:page]).per(params[:per_page] || 20)

        render_success({
          tag: Dam::TagSerializer.flat(@tag),
          assets: Dam::AssetSerializer.flat(@assets)
        })
      end

      def popular
        @tags = tenant_scope(Dam::Tag).popular.limit(params[:limit] || 20)

        # Serialize each tag individually
        serialized_tags = @tags.map do |tag|
          begin
            hash = Dam::TagSerializer.flat(tag)
            # Serializers' .flat returns the attribute hash directly
            # Check if it's wrapped in :data or return hash directly
            result = hash.is_a?(Hash) ? (hash[:data] || hash) : hash
            # Return the result if it's a valid hash (even if id is missing, let frontend handle it)
            result.is_a?(Hash) ? result : nil
          rescue => e
            Rails.logger.error "Error serializing tag #{tag.id}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            nil
          end
        end.compact

        render_success({ data: serialized_tags })
      end

      def search
        @tags = tenant_scope(Dam::Tag).where("name ILIKE ?", "%#{params[:q]}%").alphabetical.limit(params[:limit] || 20)

        # Serialize each tag individually
        serialized_tags = @tags.map do |tag|
          begin
            hash = Dam::TagSerializer.flat(tag)
            # Serializers' .flat returns the attribute hash directly
            # Check if it's wrapped in :data or return hash directly
            result = hash.is_a?(Hash) ? (hash[:data] || hash) : hash
            # Return the result if it's a valid hash (even if id is missing, let frontend handle it)
            result.is_a?(Hash) ? result : nil
          rescue => e
            Rails.logger.error "Error serializing tag #{tag.id}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            nil
          end
        end.compact

        render_success({ data: serialized_tags })
      end

      def create
        # Check if user is disabled
        if current_user.disabled?
          render_error("This account has been disabled. Please contact your administrator.", :forbidden)
          return
        end

        @tag = tenant_scope(Dam::Tag).find_or_create_by(name: params[:tag][:name].downcase.strip) do |tag|
          tag.tenant = Dam.current_tenant
        end

        if @tag.persisted?
          render_success(Dam::TagSerializer.flat(@tag), :created)
        else
          render_error(@tag.errors.full_messages.join(", "))
        end
      end

      def destroy
        @tag = tenant_scope(Dam::Tag).find(params[:id])

        # Check if user can delete this tag
        # Users can delete tags they created (through assets), owners/admins can delete any tag
        can_delete = false
        if current_user.tenant_owner? || current_user.admin?
          can_delete = true
        else
          # Check if user created assets with this tag
          user_assets_with_tag = Dam::Asset.where(tenant: Dam.current_tenant, user: current_user)
            .joins(:tags)
            .where(Dam::Tag.table_name => { id: @tag.id })
            .exists?
          can_delete = user_assets_with_tag
        end

        unless can_delete
          render_error("You do not have permission to delete this tag", :forbidden)
          return
        end

        if @tag.destroy
          render_success({ message: "Tag deleted successfully" })
        else
          render_error("Failed to delete tag")
        end
      end
    end
  end
end
