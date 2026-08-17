# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# `gemspec` only requires the gem's own lib entrypoint (which requires
# spree_core); it does not auto-`require` runtime dependencies pulled in
# transitively. spree_admin's admin routes/controllers are only loaded when
# the gem is actually required, so list it explicitly.
gem 'spree_admin'

gem 'pg'
gem 'propshaft'

group :development, :test do
  gem 'dotenv'
  gem 'rubocop'
  gem 'rubocop-rails'
  gem 'spree_dev_tools'
  gem 'vcr'
  gem 'webmock'
  gem 'yard'
end

# spree_dev_tools depends on this transitively (for `assigns` in controller
# specs) but never requires it, and it is a Railtie — requiring it after boot
# is too late to hook in.
group :test do
  gem 'rails-controller-testing'
end
