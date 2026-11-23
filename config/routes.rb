Dam::Engine.routes.draw do
  # DAM JSON API. The host mounts the engine inside its /api/v1 scope at "/", so these
  # are served at /api/v1/assets, /api/v1/tags, ... (the paths the web app calls).
  scope module: "api/v1" do
    resources :assets, only: [ :index, :show, :create, :update, :destroy ] do
      member do
        post :add_tag
        delete :remove_tag
        post :restore
        delete :purge
        post :auto_tag
        post :detect_faces
        get :faces
        post :generate_poster_frame
        post :derivatives
        get :lineage
        get :stream
      end
      collection do
        get :search
        get :recycle_bin
      end
    end

    resources :face_detections, only: [] do
      member do
        put :identify
      end
    end

    resources :face_people, only: [ :index, :show, :create, :update, :destroy ]

    resources :collections do
      member do
        post :add_asset
        delete :remove_asset
      end
      collection do
        get :public_collections
      end
    end

    resources :tags do
      collection do
        get :popular
        get :search
      end
    end

    resources :smart_folders do
      member do
        get :assets
        post :pin
        post :unpin
      end
      collection do
        get :sidebar
      end
    end

    resources :groups do
      member do
        post :add_member
        delete :remove_member
      end
    end

    resources :drop_zones do
      member do
        post :subscribe
        delete :unsubscribe
        get :files
        post :upload
      end
    end

    resources :watched_folders do
      member do
        post :scan_now
        get :scan_history
        get :notifications
      end
    end
  end
end
