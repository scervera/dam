class Dam::Api::V1::GroupsController < Dam::Api::V1::BaseController
  before_action :require_admin, except: [ :index, :show ]
  before_action :set_group, only: [ :show, :update, :destroy, :add_member, :remove_member ]

  # GET /api/v1/groups
  def index
    @groups = tenant_scope(Dam::Group).active.order(:name)
    render_success(Dam::GroupSerializer.new(@groups).serializable_hash)
  end

  # GET /api/v1/groups/:id
  def show
    render_success(Dam::GroupSerializer.new(@group, include: [ :members ]).serializable_hash)
  end

  # POST /api/v1/groups
  def create
    @group = current_user.owned_groups.build(group_params.merge(tenant: Dam.current_tenant))

    if @group.save
      render_success(Dam::GroupSerializer.new(@group).serializable_hash, :created)
    else
      render_error(@group.errors.full_messages.join(", "), :unprocessable_entity)
    end
  end

  # PATCH/PUT /api/v1/groups/:id
  def update
    if @group.update(group_params)
      render_success(Dam::GroupSerializer.new(@group).serializable_hash)
    else
      render_error(@group.errors.full_messages.join(", "), :unprocessable_entity)
    end
  end

  # DELETE /api/v1/groups/:id
  def destroy
    @group.destroy
    head :no_content
  end

  # POST /api/v1/groups/:id/add_member
  def add_member
    user = Dam.config.find_tenant_user.call(Dam.current_tenant, params[:user_id])
    role = params[:role] || "member"

    @group.add_member(user, role: role)
    render_success(Dam::GroupSerializer.new(@group.reload, include: [ :members ]).serializable_hash)
  rescue ActiveRecord::RecordNotFound
    render_error("User not found", :not_found)
  end

  # DELETE /api/v1/groups/:id/remove_member
  def remove_member
    user = Dam.config.find_tenant_user.call(Dam.current_tenant, params[:user_id])
    @group.remove_member(user)
    render_success(Dam::GroupSerializer.new(@group.reload, include: [ :members ]).serializable_hash)
  rescue ActiveRecord::RecordNotFound
    render_error("User not found", :not_found)
  end

  private

  def set_group
    @group = tenant_scope(Dam::Group).find(params[:id])
  end

  def group_params
    params.require(:group).permit(:name, :description, :active)
  end

  def require_admin
    unless current_user&.admin?
      render_error("Admin access required", :forbidden)
    end
  end
end
