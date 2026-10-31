# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::SdkLogger do
  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output, level: Logger::DEBUG) }

  describe '#log' do
    it "fills the SDK's placeholders, whichever kind of key carries the value" do
      described_class.new(logger).log(Logger::DEBUG, 'Request {method} {url} {content-type}',
                                      { 'method' => 'GET', url: 'https://paypal.test/v2/orders/1', 'content-type' => 'application/json' })

      expect(output.string).to include('[spree-paypal_merchant] Request GET https://paypal.test/v2/orders/1 application/json')
    end

    it 'leaves a placeholder with no value empty' do
      described_class.new(logger).log(Logger::DEBUG, 'Response {status-code} {content-length}', { 'status-code' => 200 })

      expect(output.string).to include('[spree-paypal_merchant] Response 200 ')
      expect(output.string).not_to include('{content-length}')
    end

    it 'writes at the level the SDK asks for, so the logger level filters it' do
      logger.level = Logger::INFO
      sdk_logger = described_class.new(logger)

      sdk_logger.log(Logger::DEBUG, 'Request {method}', { 'method' => 'GET' })
      expect(output.string).to be_empty

      sdk_logger.log(Logger::WARN, 'Request {method}', { 'method' => 'GET' })
      expect(output.string).to include('WARN').and include('Request GET')
    end

    it 'writes to the Rails log by default' do
      allow(Rails.logger).to receive(:add)

      described_class.new.log(Logger::DEBUG, 'Request {method}', { 'method' => 'GET' })

      expect(Rails.logger).to have_received(:add).with(Logger::DEBUG)
    end
  end
end
