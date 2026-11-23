Rails.application.routes.draw do
  scope "api/v1" do
    mount Dam::Engine, at: "/"
  end
end
