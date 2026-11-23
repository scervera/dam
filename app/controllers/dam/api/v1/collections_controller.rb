module Dam::Api
  module V1
    class CollectionsController < BaseController
      before_action :set_collection, only: [ :show, :update, :destroy ]
      before_action :require_user_or_admin, only: [ :create, :update, :destroy ]

      def index
        @collections = current_user.collections.includes(:assets)
        @collections = @collections.page(params[:page]).per(params[:per_page] || 20)

        render_success(Dam::CollectionSerializer.new(@collections).serializable_hash)
      end

      def show
        unless @collection.can_be_accessed_by?(current_user)
          render_error("Access denied", :forbidden)
          return
        end

        render_success(Dam::CollectionSerializer.new(@collection).serializable_hash)
      end

      def create
        # Check if user is disabled
        if current_user.disabled?
          render_error("This account has been disabled. Please contact your administrator.", :forbidden)
          return
        end

        @collection = current_user.collections.build(collection_params)
        # Ensure tenant is set (should be set by ApplicationRecord callback)
        @collection.tenant = Dam.current_tenant unless @collection.tenant

        if @collection.save
          render_success(Dam::CollectionSerializer.new(@collection).serializable_hash, :created)
        else
          render_error(@collection.errors.full_messages.join(", "))
        end
      end

      def update
        unless @collection.can_be_accessed_by?(current_user)
          render_error("Access denied", :forbidden)
          return
        end

        if @collection.update(collection_params)
          render_success(Dam::CollectionSerializer.new(@collection).serializable_hash)
        else
          render_error(@collection.errors.full_messages.join(", "))
        end
      end

      def destroy
        # Check if user can delete this collection
        # Users can delete collections they created, owners/admins can delete any collection
        can_delete = false
        if current_user.tenant_owner? || current_user.admin?
          can_delete = true
        elsif current_user.dam_writer? && @collection.user_id == current_user.id
          can_delete = true
        end

        unless can_delete
          render_error("You do not have permission to delete this collection", :forbidden)
          return
        end

        if @collection.destroy
          render_success({ message: "Collection deleted successfully" })
        else
          render_error("Failed to delete collection")
        end
      end

      def add_asset
        @collection = tenant_scope(current_user.collections).find(params[:id])
        @asset = tenant_scope(current_user.assets).find(params[:asset_id])

        if @collection.add_asset(@asset)
          render_success({ message: "Asset added to collection successfully" })
        else
          render_error("Failed to add asset to collection")
        end
      end

      def remove_asset
        @collection = tenant_scope(current_user.collections).find(params[:id])
        @asset = tenant_scope(current_user.assets).find(params[:asset_id])

        if @collection.remove_asset(@asset)
          render_success({ message: "Asset removed from collection successfully" })
        else
          render_error("Failed to remove asset from collection")
        end
      end

      def public_collections
        @collections = tenant_scope(Dam::Collection).public_collections.includes(:user, :assets)
        @collections = @collections.page(params[:page]).per(params[:per_page] || 20)

        render_success(Dam::CollectionSerializer.new(@collections).serializable_hash)
      end

      private

      def set_collection
        @collection = tenant_scope(current_user.collections).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_error("Collection not found", :not_found)
      end

      def collection_params
        params.require(:collection).permit(:name, :description, :is_public)
      end
    end
  end
end
