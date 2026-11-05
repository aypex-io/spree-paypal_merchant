# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# CI runs a matrix of Spree versions. SPREE_VERSION pins one (e.g. '6.0.0');
# left unset, Bundler resolves the newest release the gemspec allows.
spree_version = ENV.fetch('SPREE_VERSION', '')
gem 'spree', spree_version unless spree_version.empty?

gem 'pg'
gem 'propshaft'

# Spree's stringex requires ostruct without depending on it, and Ruby 4.0 no
# longer ships it as a default gem. oj used to pull it in, until oj 3.17.8.
gem 'ostruct'

group :development, :test do
  gem 'dotenv'
  gem 'rubocop'
  gem 'rubocop-rails'
  gem 'spree_dev_tools', '>= 1.0.0.beta2'
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
