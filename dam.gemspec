require_relative "lib/dam/version"

Gem::Specification.new do |spec|
  spec.name        = "dam"
  spec.version     = Dam::VERSION
  spec.authors     = [ "Cervera Ventures LLC" ]
  spec.summary     = "Multi-tenant digital asset management engine for Rails"
  spec.description = "A mountable Rails engine for digital asset management: uploads with " \
                     "thumbnails and derivatives, tags, collections, smart folders, drop zones, " \
                     "watched folders, groups, AI auto-tagging and face recognition, served as a " \
                     "JSON API. Host applications plug in their own tenants, users, " \
                     "authentication and storage through Dam.config."
  # Source-available, not OSI open source: free for noncommercial use; commercial use
  # requires a separate license from Cervera Ventures LLC.
  spec.license = "PolyForm-Noncommercial-1.0.0"
  spec.homepage = "https://github.com/scervera/dam"
  spec.required_ruby_version = ">= 3.2"

  # Distributed from GitHub (Bundler git source), not a gem server. This blocks an
  # accidental `gem push` (an .invalid host never resolves).
  spec.metadata["allowed_push_host"] = "https://gem-server-not-chosen.invalid"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "CHANGELOG.md", "LICENSE.md", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0.3"
  spec.add_dependency "pg", "~> 1.1"
  spec.add_dependency "jsonapi-serializer", "~> 2.2"
  spec.add_dependency "pundit", "~> 2.3"
  spec.add_dependency "kaminari", "~> 1.2"
  spec.add_dependency "image_processing", "~> 1.2"
  spec.add_dependency "ruby-vips", "~> 2.2"
  spec.add_dependency "streamio-ffmpeg", "~> 3.0"
  spec.add_dependency "exifr", "~> 1.3"
  spec.add_dependency "mini_exiftool", "~> 2.10"
  # Face recognition (optional, configured by ENV).
  spec.add_dependency "aws-sdk-rekognition", "~> 1.0"
  # AI auto-tagging SDKs are not dependencies: a host adds the one for its provider
  # ("ruby-openai" for openai/openai_compatible, "anthropic" for anthropic). See README.
end
