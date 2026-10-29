# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require File.expand_path('dummy/config/environment.rb', __dir__)
require 'spree_dev_tools/rspec/spec_helper'
require 'spree/paypal_merchant/factories'

Dir[File.join(File.dirname(__FILE__), 'support/**/*.rb')].each { |f| require f }
