# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::OrderPresenter do
  # A cart during checkout: one line of 10.00, nothing else.
  let(:cart) { create(:cart_with_line_items) }
  subject { described_class.new(cart) }

  let(:body) { subject.to_json['body'] }
  let(:purchase_unit) { body.purchase_units[0] }
  let(:amount) { purchase_unit.amount }
  let(:breakdown) { amount.breakdown }
  let(:items) { purchase_unit.items }

  # A handling fee on the cart, with the totals recalculated to include it.
  def add_fee(cart, fee_amount)
    create(:fee, order: nil, cart: cart, amount: fee_amount)
    cart.recalculate_totals!
  end

  def breakdown_sum
    breakdown.item_total.value.to_d + breakdown.shipping.value.to_d + (breakdown.handling&.value || 0).to_d +
      breakdown.tax_total.value.to_d - breakdown.discount.value.to_d
  end

  context 'line_item.name' do
    let(:line_item) { cart.line_items.first }

    context 'when line_item.name is longer than 127 characters' do
      before { allow(line_item).to receive(:name).and_return('A' * 200) }

      it 'truncates to 127 characters' do
        expect(items.first.name.length).to eq(127)
      end
    end

    context 'when line_item.name is nil' do
      before { allow(line_item).to receive(:name).and_return(nil) }

      it 'handles nil without raising' do
        expect(items.first.name).to eq('')
      end
    end
  end

  context 'breakdown' do
    let(:cart) { create(:cart_ready_for_delivery) }

    context 'when the cart has a fee' do
      before { add_fee(cart, 2) }

      it 'sends the fee total as handling' do
        expect(breakdown.handling.value).to eq('2.00')
      end

      it 'sends the delivery total as shipping' do
        expect(breakdown.shipping.value).to eq('10.00')
      end

      it 'sends the item total' do
        expect(breakdown.item_total.value).to eq('10.00')
      end

      it 'charges the cart total, as currency text' do
        expect(amount.value).to eq('22.00')
      end

      it 'adds up to the amount PayPal charges' do
        expect(breakdown_sum).to eq(amount.value.to_d)
      end
    end

    context 'when the cart has no fees' do
      it 'omits handling' do
        expect(breakdown.handling).to be_nil
      end

      it 'adds up to the amount PayPal charges' do
        expect(breakdown_sum).to eq(amount.value.to_d)
      end
    end
  end

  context 'discount' do
    # A discount row on the cart's line, with the totals recalculated to take it off.
    def add_manual_discount(cart, discount_amount)
      create(:discount, line_item: cart.line_items.first, order: nil, cart: cart, kind: 'manual', amount: -discount_amount)
      cart.recalculate_totals!
    end

    def add_promotion_discount(cart, discount_amount)
      promotion = create(:promotion_with_order_adjustment, weighted_order_adjustment_amount: discount_amount)
      create(:order_promotion, order: nil, cart: cart, promotion: promotion)
      cart.recalculate_totals!
    end

    it 'sends zero when nothing is discounted' do
      expect(breakdown.discount.value).to eq('0.00')
    end

    context 'when a promotion discounts the cart' do
      before { add_promotion_discount(cart, 3) }

      it 'passes a positive number to PayPal for the negative discount' do
        expect(breakdown.discount.value).to eq('3.00')
      end

      it 'adds up to the amount PayPal charges' do
        expect([amount.value, breakdown_sum]).to eq(['7.00', 7.to_d])
      end
    end

    # Spree's discount_total counts promotions only, but the total takes off a
    # manual discount too.
    context 'when a manual discount takes money off the cart' do
      before { add_manual_discount(cart, 3) }

      it 'counts the manual discount' do
        expect(breakdown.discount.value).to eq('3.00')
      end

      it 'adds up to the amount PayPal charges' do
        expect([amount.value, breakdown_sum]).to eq(['7.00', 7.to_d])
      end

      it 'still sends the items' do
        expect(items).not_to be_nil
      end
    end

    context 'when a promotion and a manual discount both apply' do
      before do
        add_promotion_discount(cart, 3)
        add_manual_discount(cart, 2)
      end

      it 'counts both' do
        expect(breakdown.discount.value).to eq('5.00')
      end

      it 'adds up to the amount PayPal charges' do
        expect([amount.value, breakdown_sum]).to eq(['5.00', 5.to_d])
      end
    end
  end

  # PayPal refuses an order whose breakdown doesn't add up to the amount, so
  # when it can't, the amount goes alone.
  context 'when the totals cannot balance' do
    let(:cart) { create(:cart_ready_for_delivery) }

    # Delivery moved without the total following it.
    before do
      cart.update_columns(delivery_total: 4) # rubocop:disable Rails/SkipsModelValidations
    end

    it 'sends the amount, as the total' do
      expect(amount.value).to eq('20.00')
    end

    it 'sends no breakdown' do
      expect(breakdown).to be_nil
    end

    it 'sends no items' do
      expect(items).to be_nil
    end

    it 'still sends the shipping address' do
      expect(purchase_unit.shipping).not_to be_nil
    end
  end

  context 'tax_total breakdown (PayPal AMOUNT_MISMATCH guard)' do
    context 'tax-inclusive cart (e.g. UK/EU VAT)' do
      before do
        allow(cart).to receive_messages(item_total: 120.0, included_tax_total: 20.0, additional_tax_total: 0.0, tax_total: 20.0,
                                        delivery_total: 0.0, total: 120.0)
      end

      it 'sends only additional tax so it does not double-count included VAT' do
        expect(breakdown.tax_total.value).to eq('0.00')
      end

      it 'reconciles value == item_total + tax_total + shipping - discount' do
        expect(breakdown_sum).to eq(cart.total.to_d)
      end
    end

    context 'tax-exclusive cart (e.g. US)' do
      before do
        allow(cart).to receive_messages(item_total: 100.0, included_tax_total: 0.0, additional_tax_total: 8.0, tax_total: 8.0,
                                        delivery_total: 5.0, total: 113.0)
      end

      it 'sends additional_tax_total' do
        expect(breakdown.tax_total.value).to eq('8.00')
      end

      it 'reconciles value == item_total + tax_total + shipping - discount' do
        expect(breakdown_sum).to eq(amount.value.to_d)
      end
    end
  end

  context 'items' do
    context 'when unit prices have two decimals' do
      let(:cart) { create(:cart_with_line_items, line_items_count: 2, line_items_price: BigDecimal('12.34')) }

      it 'sends the items, each at its unit price' do
        expect(items.map { |item| item.unit_amount.value }).to eq(%w[12.34 12.34])
      end

      it 'sends items that add up to the item total' do
        sum = items.sum { |item| item.unit_amount.value.to_d * item.quantity.to_i }
        expect(sum).to eq(breakdown.item_total.value.to_d)
      end
    end

    context 'when a unit price has four decimals' do
      let(:cart) { create(:cart_with_line_items, line_items_count: 0) }

      before do
        create(:line_item, cart: cart, order: nil, price: BigDecimal('1.2345'), quantity: 3)
        cart.line_items.reload
        cart.recalculate_totals!
      end

      it 'rounds the item total to the currency' do
        expect(breakdown.item_total.value).to eq('3.70')
      end

      # 3 x 1.23 is 3.69 against the 3.70 line total, which PayPal would reject
      # as an item total mismatch.
      it 'sends no items, because they cannot add up to the item total' do
        expect(items).to be_nil
      end

      it 'keeps the breakdown' do
        expect(breakdown_sum).to eq(amount.value.to_d)
      end
    end
  end

  context 'in a currency without decimals' do
    let(:store) { create(:store, default_currency: 'JPY', supported_currencies: 'JPY') }
    let(:cart) { create(:cart_with_line_items, store: store, currency: 'JPY', line_items_price: BigDecimal('1500')) }

    it 'sends every amount without decimals' do
      expect(
        [amount.value, breakdown.item_total.value, breakdown.shipping.value, breakdown.tax_total.value, breakdown.discount.value,
         items.first.unit_amount.value]
      ).to eq(%w[1500 1500 0 0 0 1500])
    end

    it 'names the currency on every amount' do
      expect([amount.currency_code, breakdown.item_total.currency_code, items.first.unit_amount.currency_code]).to all(eq('JPY'))
    end
  end

  context 'charge amount (gift card / store credit covers part of the order)' do
    let(:cart) { create(:cart_ready_for_delivery) }

    before { add_fee(cart, 2) }

    it 'charges the cart total by default' do
      expect(amount.value).to eq('22.00')
    end

    context 'when the amount due is less than the cart total' do
      subject { described_class.new(cart, amount: cart.total - 10) }

      it 'charges only the amount due, not the full total' do
        expect(amount.value).to eq('12.00')
      end

      it 'omits the breakdown and items, which would sum to the full total' do
        expect(breakdown).to be_nil
        expect(items).to be_nil
      end
    end

    context 'when the amount due is the cart total' do
      subject { described_class.new(cart, amount: cart.total) }

      it 'keeps the breakdown and items' do
        expect(breakdown).not_to be_nil
        expect(items).not_to be_nil
      end
    end
  end

  context 'provided shipping address (storefront owns the address)' do
    context 'when the cart has a ship address' do
      let(:cart) { create(:cart_ready_for_delivery) }
      let(:ship_address) { cart.ship_address }

      def address
        purchase_unit.shipping.address
      end

      it 'sends the storefront-collected address to PayPal' do
        expect(address.address_line_1).to eq(ship_address.address1)
      end

      it 'sends the postal code and country code' do
        expect([address.postal_code, address.country_code]).to eq([ship_address.postal_code, 'US'])
      end

      it 'sends the state code as the region' do
        expect(address.admin_area_1).to eq(ship_address.state_code)
      end

      it 'pins the address so the PayPal wallet does not re-collect it' do
        expect(body.payment_source.paypal.experience_context.shipping_preference)
          .to eq(PaypalServerSdk::PaypalWalletContextShippingPreference::SET_PROVIDED_ADDRESS)
      end

      context 'when the address has a free-text state instead of a state code' do
        let(:ship_address) { build_stubbed(:address, state: nil, state_name: 'Free Text Region') }

        before { allow(cart).to receive(:ship_address).and_return(ship_address) }

        it 'sends the state name as the region' do
          expect(address.admin_area_1).to eq('Free Text Region')
        end
      end
    end

    context 'when the cart has no ship address' do
      before { allow(cart).to receive(:ship_address).and_return(nil) }

      it 'sends no shipping details' do
        expect(purchase_unit.shipping).to be_nil
      end

      it 'disables the PayPal shipping step' do
        expect(body.payment_source.paypal.experience_context.shipping_preference)
          .to eq(PaypalServerSdk::PaypalWalletContextShippingPreference::NO_SHIPPING)
      end
    end
  end

  # The suite raises on a Spree deprecation, so building the whole payload from
  # a cart with every kind of total and an address is the check that it reads
  # only current Spree names.
  context 'with every kind of total and an address' do
    let(:cart) { create(:cart_ready_for_delivery) }

    before { add_fee(cart, 2) }

    it 'uses no deprecated Spree names' do
      expect { subject.to_json }.not_to raise_error
    end
  end

  context 'when the owner is a placed order' do
    let(:cart) { create(:cart_ready_to_complete) }
    let(:order) do
      Spree::Carts::Complete.call(cart: cart)
      cart.reload.order
    end

    subject { described_class.new(order) }

    it 'reads the order totals' do
      expect([amount.value, breakdown.item_total.value, breakdown.shipping.value]).to eq(%w[20.00 10.00 10.00])
    end

    it 'adds up to the amount PayPal charges' do
      expect(breakdown_sum).to eq(amount.value.to_d)
    end
  end
end
