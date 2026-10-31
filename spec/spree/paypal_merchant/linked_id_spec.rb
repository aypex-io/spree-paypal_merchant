# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant do
  describe '.linked_id' do
    let(:links) do
      [
        { 'href' => 'https://api.paypal.com/v2/payments/refunds/REFUND-1', 'rel' => 'self', 'method' => 'GET' },
        { 'href' => 'https://api.paypal.com/v2/payments/captures/CAPTURE-1/refund', 'rel' => 'refund', 'method' => 'POST' },
        { 'href' => 'https://api.paypal.com/v2/payments/captures/CAPTURE-1', 'rel' => 'up', 'method' => 'GET' }
      ]
    end

    it 'reads the id from the link with the relation' do
      expect(described_class.linked_id(links, rel: 'up', path: 'v2/payments/captures')).to eq('CAPTURE-1')
    end

    it 'reads links with symbol keys' do
      expect(described_class.linked_id(links.map(&:symbolize_keys), rel: 'up', path: 'v2/payments/captures')).to eq('CAPTURE-1')
    end

    it 'is nil when the link points at another kind of resource' do
      expect(described_class.linked_id(links, rel: 'up', path: 'v2/checkout/orders')).to be_nil
    end

    it 'is nil when there is no link with the relation' do
      expect(described_class.linked_id(links, rel: 'collection', path: 'v2/payments/captures')).to be_nil
    end

    it 'is nil for no links' do
      expect(described_class.linked_id(nil, rel: 'up', path: 'v2/payments/captures')).to be_nil
    end

    it 'ignores what is not a link' do
      expect(described_class.linked_id(['up', 42], rel: 'up', path: 'v2/payments/captures')).to be_nil
    end
  end
end
