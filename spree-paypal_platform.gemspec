# frozen_string_literal: true

require_relative 'lib/spree/paypal_platform/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'spree-paypal_platform'
  s.version     = Spree::PaypalPlatform::VERSION
  s.summary     = 'PayPal Checkout for Spree, including Apple Pay and Card Fields'
  s.description = 'A Spree 5.6+ payment method for PayPal Checkout. Creates and ' \
                  'captures PayPal Orders via payment sessions, pins the storefront ' \
                  'address, and records PayPal wallet, Apple Pay, and card sources.'
  s.required_ruby_version = '>= 3.3'

  s.author   = 'Aypex'
  s.email    = 'hello@aypex.io'
  s.homepage = 'https://github.com/aypex-io/spree-paypal_platform'
  s.license  = 'MIT'

  s.metadata = {
    'source_code_uri' => s.homepage,
    'bug_tracker_uri' => "#{s.homepage}/issues",
    'changelog_uri' => "#{s.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  s.files = Dir['{app,config,db,lib}/**/*', 'LICENSE', 'Rakefile', 'README.md', 'CHANGELOG.md']
  s.require_path = 'lib'

  spree_opts = '>= 5.6.0'
  s.add_dependency 'paypal-server-sdk', '~> 2.3'
  s.add_dependency 'spree', spree_opts
  s.add_dependency 'spree_admin', spree_opts

  s.add_development_dependency 'dotenv'
  s.add_development_dependency 'spree_dev_tools'
  s.add_development_dependency 'vcr'
  s.add_development_dependency 'webmock'
end
