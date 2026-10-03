# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::OrderPresenter do
  let(:order) { build_stubbed(:order, line_items: [line_item]) }
  subject { described_class.new(order) }

  context 'line_item.name' do
    context 'when line_item.name is longer than 127 characters' do
      let(:line_item) do
        item = build_stubbed(:line_item)
        allow(item).to receive(:name).and_return('A' * 200)
        item
      end

      it 'truncates to 127 characters' do
        item = subject.to_json['body'].purchase_units[0].items.first
        expect(item.name.length).to eq(127)
      end
    end

    context 'when line_item.name is nil' do
      let(:line_item) do
        item = build_stubbed(:line_item)
        allow(item).to receive(:name).and_return(nil)
        item
      end

      it 'handles nil without raising' do
        expect(subject.to_json['body'].purchase_units[0].items.first.name).to eq('')
      end
    end
  end

  context 'discount' do
    let(:line_item) do
      item = build_stubbed(:line_item)
      allow(item).to receive(:name).and_return('Item')
      item
    end

    it 'passes a positive number to PayPal for a negative promo_total' do
      allow(order).to receive(:promo_total).and_return(-100)
      expect(subject.to_json['body'].purchase_units[0].amount.breakdown.discount.value).to eq('100')
    end
  end

  context 'tax_total breakdown (PayPal AMOUNT_MISMATCH guard)' do
    let(:line_item) do
      item = build_stubbed(:line_item)
      allow(item).to receive(:name).and_return('Item')
      item
    end

    def breakdown
      subject.to_json['body'].purchase_units[0].amount.breakdown
    end

    context 'tax-inclusive order (e.g. UK/EU VAT)' do
      before do
        allow(order).to receive(:item_total).and_return(120.0)
        allow(order).to receive(:included_tax_total).and_return(20.0)
        allow(order).to receive(:additional_tax_total).and_return(0.0)
        allow(order).to receive(:tax_total).and_return(20.0)
        allow(order).to receive(:ship_total).and_return(0.0)
        allow(order).to receive(:promo_total).and_return(0)
        allow(order).to receive(:total).and_return(120.0)
      end

      it 'sends only additional tax so it does not double-count included VAT' do
        expect(breakdown.tax_total.value).to eq('0.0')
      end

      it 'reconciles value == item_total + tax_total + shipping - discount' do
        sum = breakdown.item_total.value.to_d + breakdown.tax_total.value.to_d +
              breakdown.shipping.value.to_d - breakdown.discount.value.to_d
        expect(sum).to eq(order.total.to_d)
      end
    end

    context 'tax-exclusive order (e.g. US)' do
      before do
        allow(order).to receive(:item_total).and_return(100.0)
        allow(order).to receive(:included_tax_total).and_return(0.0)
        allow(order).to receive(:additional_tax_total).and_return(8.0)
        allow(order).to receive(:tax_total).and_return(8.0)
        allow(order).to receive(:ship_total).and_return(5.0)
        allow(order).to receive(:promo_total).and_return(0)
        allow(order).to receive(:total).and_return(113.0)
      end

      it 'sends additional_tax_total' do
        expect(breakdown.tax_total.value).to eq('8.0')
      end
    end
  end

  context 'charge amount (gift card / store credit covers part of the order)' do
    let(:line_item) do
      item = build_stubbed(:line_item)
      allow(item).to receive(:name).and_return('Item')
      item
    end

    before do
      allow(order).to receive(:item_total).and_return(75.0)
      allow(order).to receive(:additional_tax_total).and_return(0.0)
      allow(order).to receive(:ship_total).and_return(3.0)
      allow(order).to receive(:promo_total).and_return(0)
      allow(order).to receive(:total).and_return(78.0)
    end

    def amount_for(presenter)
      presenter.to_json['body'].purchase_units[0].amount
    end

    it 'charges the order total by default' do
      expect(amount_for(subject).value).to eq('78.0')
    end

    context 'when the amount due is less than the order total' do
      subject { described_class.new(order, amount: 58.0) }

      it 'charges only the amount due, not the full order total' do
        expect(amount_for(subject).value).to eq('58.0')
      end

      it 'omits the breakdown and items, which would sum to the full total' do
        expect(amount_for(subject).breakdown).to be_nil
        expect(subject.to_json['body'].purchase_units[0].items).to be_nil
      end
    end
  end

  context 'provided shipping address (storefront owns the address)' do
    let(:line_item) do
      item = build_stubbed(:line_item)
      allow(item).to receive(:name).and_return('Item')
      item
    end

    def body
      subject.to_json['body']
    end

    context 'when the order has a ship address' do
      let(:ship_address) { build_stubbed(:address) }
      before { allow(order).to receive(:ship_address).and_return(ship_address) }

      it 'sends the storefront-collected address to PayPal' do
        address = body.purchase_units[0].shipping.address
        expect(address.address_line_1).to eq(ship_address.address1)
      end

      it 'pins the address so the PayPal wallet does not re-collect it' do
        expect(body.payment_source.paypal.experience_context.shipping_preference)
          .to eq(PaypalServerSdk::PaypalWalletContextShippingPreference::SET_PROVIDED_ADDRESS)
      end
    end

    context 'when the order has no ship address' do
      before { allow(order).to receive(:ship_address).and_return(nil) }

      it 'disables the PayPal shipping step' do
        expect(body.payment_source.paypal.experience_context.shipping_preference)
          .to eq(PaypalServerSdk::PaypalWalletContextShippingPreference::NO_SHIPPING)
      end
    end
  end
end
