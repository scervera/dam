module DamSpecHelpers
  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+q3xkAAAAASUVORK5CYII=")

  def create_tenant(name = "Acme") = Tenant.create!(name: name)

  def create_user(tenant, role: "writer")
    User.create!(tenant: tenant, role: role, email: "#{SecureRandom.hex(4)}@example.com",
                 api_token: SecureRandom.hex(16))
  end

  def create_asset(user, name: "photo.png")
    Dam.current_tenant = user.tenant
    asset = Dam::Asset.new(name: name, tenant: user.tenant, user: user)
    asset.file.attach(io: StringIO.new(PNG), filename: name, content_type: "image/png")
    asset.save!
    asset
  end

  def auth(user) = { "Authorization" => "Bearer #{user.api_token}" }
end
