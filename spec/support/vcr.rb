# frozen_string_literal: true

require 'vcr'
require 'webmock/rspec'

WebMock.disable_net_connect!(net_http_connect_on_start: true, allow_localhost: true)

VCR.configure do |c|
  c.allow_http_connections_when_no_cassette = false
  c.cassette_library_dir = File.join(Spree::PaypalCheckout::Engine.root, 'spec', 'vcr')
  c.hook_into :webmock
  c.ignore_localhost = true
  c.configure_rspec_metadata!
  c.default_cassette_options = { record: :none }

  c.filter_sensitive_data('<PAYPAL_CLIENT_ID>') { ENV.fetch('PAYPAL_CLIENT_ID', nil) }
  c.filter_sensitive_data('<PAYPAL_CLIENT_SECRET>') { ENV.fetch('PAYPAL_CLIENT_SECRET', nil) }

  c.before_record do |interaction|
    header_names = %w[Authorization]
    headers = header_names.flat_map { |header_name| interaction.request.headers[header_name] }.compact

    headers.each { |header| interaction.filter!(header, '<FILTERED>') }
  end
end
