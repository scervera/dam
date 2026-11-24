source "https://rubygems.org"

# Runtime dependencies are declared in dam.gemspec.
gemspec

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

group :development, :test do
  gem "rspec-rails", "~> 6.1"

  # AI provider SDKs are optional at runtime (hosts add the one they use); the specs
  # exercise every adapter.
  gem "anthropic", "~> 2.13"
  gem "ruby-openai", "~> 7.0"
  gem "webmock", "~> 3.23"
end
