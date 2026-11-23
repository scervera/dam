# Satisfies Dam.config.parent_controller's contract with a simple bearer token.
class ApplicationController < ActionController::API
  include Pundit::Authorization

  before_action :authenticate_user!

  rescue_from(Pundit::NotAuthorizedError) { render_error("Forbidden", :forbidden) }

  attr_reader :current_user

  private

  def authenticate_user!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    @current_user = User.find_by(api_token: token) if token.present?
    return render_error("Unauthorized", :unauthorized) unless @current_user

    Dam.current_user = @current_user
    Dam.current_tenant = @current_user.tenant
  end

  def tenant_scope(relation) = relation.where(tenant: Dam.current_tenant)
  def render_success(data, status = :ok) = render(json: data, status: status)
  def render_error(message, status = :unprocessable_entity) = render(json: { error: message }, status: status)
end
