# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require File.expand_path('dummy/config/environment.rb', __dir__)
require 'spree_dev_tools/rspec/spec_helper'
require 'spree/paypal_checkout/factories'

raise 'spree_admin is not loaded -- check the Gemfile requires it directly (not just via `gemspec`)' unless defined?(Spree::Admin::Engine)

Dir[File.join(File.dirname(__FILE__), 'support/**/*.rb')].each { |f| require f }
