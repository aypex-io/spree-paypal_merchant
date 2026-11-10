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

  # What PayPal adds up: charges less discounts, all as sent.
  def breakdown_sum
    value = ->(field) { (breakdown.public_send(field)&.value || 0).to_d }
    %i[item_total shipping handling tax_total].sum(&value) - %i[shipping_discount discount].sum(&value)
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

    it 'omits the shipping discount when there is none' do
      expect(breakdown.shipping_discount).to be_nil
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

    # A small cart with dear shipping: the free-shipping discount is bigger than
    # the item total, so it can't go in `discount`.
    context 'when a free-shipping promotion discounts delivery' do
      let(:cart) { create(:cart_ready_for_delivery, shipping_cost: 15) }

      before do
        create(:order_promotion, order: nil, cart: cart, promotion: create(:free_shipping_promotion))
        cart.recalculate_totals!
      end

      it 'sends the shipping cost, whole' do
        expect(breakdown.shipping.value).to eq('15.00')
      end

      it 'sends the discount as the shipping discount' do
        expect(breakdown.shipping_discount.value).to eq('15.00')
      end

      it 'keeps it out of the item discount' do
        expect(breakdown.discount.value).to eq('0.00')
      end

      it 'adds up to the amount PayPal charges' do
        expect([amount.value, breakdown_sum]).to eq(['10.00', 10.to_d])
      end

      it 'still sends the items' do
        expect(items).not_to be_nil
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

  # PayPal refuses an order whose breakdown doesn't add up to the amount, or
  # has a negative figure, so when it can't be sent the amount goes alone.
  shared_examples 'an amount sent alone' do |total|
    it 'sends the amount, as the total' do
      expect(amount.value).to eq(total)
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

  context 'when the totals cannot balance' do
    let(:cart) { create(:cart_ready_for_delivery) }

    # Delivery moved without the total following it.
    before do
      cart.update_columns(delivery_total: 4) # rubocop:disable Rails/SkipsModelValidations
    end

    it_behaves_like 'an amount sent alone', '20.00'
  end

  context 'when the tax total is negative' do
    let(:cart) { create(:cart_ready_for_delivery) }

    # 10.00 + 10.00 - 2.00 is the 18.00 total, so only the sign is wrong.
    before do
      cart.update_columns(additional_tax_total: -2, total: 18) # rubocop:disable Rails/SkipsModelValidations
    end

    it_behaves_like 'an amount sent alone', '18.00'
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

    context 'with shipping and a fee' do
      let(:cart) { create(:cart_ready_for_delivery, store: store, currency: 'JPY', line_items_price: BigDecimal('1500')) }

      # The delivery needs a stock location and a delivery method in the store.
      before do
        create(:stock_location, store: store)
        create(:delivery_method, store: store).calculator.tap do |calculator|
          calculator.preferred_amount = 500
          calculator.preferred_currency = 'JPY'
          calculator.save!
        end
        add_fee(cart, 200)
      end

      it 'sends every amount as whole yen' do
        expect(
          [amount.value, breakdown.item_total.value, breakdown.shipping.value, breakdown.handling.value, breakdown.tax_total.value,
           breakdown.discount.value]
        ).to eq(%w[2200 1500 500 200 0 0])
      end

      it 'adds up to the amount PayPal charges' do
        expect(breakdown_sum).to eq(2200)
      end
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

    context 'with a manual discount on the order' do
      before do
        create(:discount, line_item: order.line_items.first, order: order, cart: nil, amount: -3)
        order.recalculate_totals!
      end

      it 'counts the manual discount' do
        expect(breakdown.discount.value).to eq('3.00')
      end

      it 'adds up to the amount PayPal charges' do
        expect([amount.value, breakdown_sum]).to eq(['17.00', 17.to_d])
      end
    end
  end

  # The buyer picks the address and the delivery in PayPal's popup, so the
  # order offers the cart's delivery rates instead of pinning an address.
  describe 'express' do
    # Delivery at 10.00 (selected) or 15.00, on the cart's one fulfillment.
    let(:cart) do
      create(:cart_ready_for_delivery).tap do |cart|
        create(:delivery_method, store: cart.store).calculator.tap do |calculator|
          calculator.preferred_amount = 15
          calculator.preferred_currency = cart.currency
          calculator.save!
        end
        cart.rebuild_fulfillments!
        cart.set_fulfillments_cost
        cart.recalculate_totals!
      end
    end
    let(:delivery_rates) { cart.fulfillments.sole.delivery_rates }
    let(:options) { purchase_unit.shipping.options }

    subject { described_class.new(cart, express: true) }

    it 'asks PayPal to collect the address' do
      expect([body.payment_source.paypal.experience_context.shipping_preference, purchase_unit.shipping&.address])
        .to eq([PaypalServerSdk::PaypalWalletContextShippingPreference::GET_FROM_FILE, nil])
    end

    it "offers the cart's delivery rates as shipping options" do
      selected = options.select(&:selected)

      expect([options.map(&:id), selected.size, selected.first&.amount&.value])
        .to eq([delivery_rates.map { |rate| rate.delivery_method.prefixed_id }, 1, breakdown.shipping.value])
    end

    it 'labels each option with its rate name, as shipping at the rate cost' do
      expect(options.map { |option| [option.label, option.type, option.amount.value] }).to eq(
        delivery_rates.map { |rate| [rate.name, PaypalServerSdk::ShippingType::SHIPPING, format('%.2f', rate.cost)] }
      )
    end

    it 'cuts a long rate name to 127 characters' do
      delivery_rates.each { |rate| rate.update_columns(name: 'A' * 200) } # rubocop:disable Rails/SkipsModelValidations

      expect(options.map { |option| option.label.length }).to all(eq(127))
    end

    it 'counts a gift card or store credit as a discount' do
      presenter = described_class.new(cart, amount: cart.total - 10, express: true)
      amount = presenter.to_json['body'].purchase_units[0].amount
      value = ->(field) { (amount.breakdown.public_send(field)&.value || 0).to_d }
      sum = %i[item_total shipping handling tax_total].sum(&value) - %i[shipping_discount discount].sum(&value)

      expect([amount.value, sum, value.call(:discount) >= 10]).to eq([format('%.2f', cart.total - 10), (cart.total - 10).to_d, true])
    end

    # 15.00 of the 20.00 total paid by credit is a discount bigger than the
    # 10.00 of goods, which PayPal refuses.
    context 'when a gift card or store credit is larger than the item total' do
      subject { described_class.new(cart, amount: cart.total - 15, express: true) }

      # Compared as plain values: a failing match on the SDK's objects raises
      # inside the SDK instead of reporting the difference.
      it 'sends the amount alone and no options' do
        expect([amount.breakdown.nil?, subject.shipping_options.map(&:id), amount.value]).to eq([true, [], format('%.2f', cart.total - 15)])
      end
    end

    # Freight quoted after review has no price yet: PayPal would show it as free.
    context 'when a rate the buyer has not chosen is unpriced' do
      before { delivery_rates.find_by(selected: false).update_columns(unpriced: true, cost: 0) } # rubocop:disable Rails/SkipsModelValidations

      it 'offers only the priced rates' do
        expect(options.map(&:id)).to eq([delivery_rates.find_by(selected: true).delivery_method.prefixed_id])
      end
    end

    context 'when a rate the buyer has not chosen has no cost' do
      before { delivery_rates.find_by(selected: false).update_columns(cost: nil) } # rubocop:disable Rails/SkipsModelValidations

      it 'offers only the priced rates' do
        expect(options.map(&:id)).to eq([delivery_rates.find_by(selected: true).delivery_method.prefixed_id])
      end
    end

    context 'when the selected rate is unpriced' do
      before { delivery_rates.find_by(selected: true).update_columns(unpriced: true) } # rubocop:disable Rails/SkipsModelValidations

      it 'offers no options' do
        expect(subject.shipping_options.map(&:id)).to eq([])
      end
    end

    # Tax moved without the total following it. Delivery still matches the
    # selected rate, so only the balance keeps the options out.
    context 'when the breakdown cannot balance' do
      before { cart.update_columns(additional_tax_total: 1) } # rubocop:disable Rails/SkipsModelValidations

      it 'sends the amount alone and no options' do
        expect([amount.breakdown, subject.shipping_options]).to eq([nil, []])
      end
    end

    context 'when no delivery rate is selected' do
      before { delivery_rates.update_all(selected: false) } # rubocop:disable Rails/SkipsModelValidations

      it 'offers no options' do
        expect(subject.shipping_options).to eq([])
      end
    end

    # PayPal refuses a selected option that costs other than the breakdown's shipping.
    context 'when the selected rate costs other than the delivery total' do
      before { delivery_rates.find_by(selected: true).update_columns(cost: 12) } # rubocop:disable Rails/SkipsModelValidations

      it 'offers no options' do
        expect(subject.shipping_options).to eq([])
      end

      it 'sends no shipping details' do
        expect(purchase_unit.shipping).to be_nil
      end
    end

    # PayPal takes at most 10 options and refuses an order with more. Rates
    # come cheapest first: 10.00, 15.00, then 16.00 to 26.00.
    context 'when the cart has more than 10 delivery rates' do
      before do
        (16..26).each do |amount|
          create(:delivery_method, store: cart.store).calculator.tap do |calculator|
            calculator.preferred_amount = amount
            calculator.preferred_currency = cart.currency
            calculator.save!
          end
        end
        cart.rebuild_fulfillments!
        cart.set_fulfillments_cost
        cart.recalculate_totals!
      end

      def method_ids(rates)
        rates.map { |rate| rate.delivery_method.prefixed_id }
      end

      it 'offers the first 10' do
        expect([delivery_rates.size, options.map(&:id)]).to eq([13, method_ids(delivery_rates.first(10))])
      end

      it 'keeps the selected rate, with the first 9 others' do
        fulfillment = cart.fulfillments.sole
        fulfillment.selected_delivery_rate_id = delivery_rates.last.id
        cart.recalculate_totals!

        expect([options.map(&:id), options.find(&:selected)&.id])
          .to eq([method_ids(delivery_rates.first(9) + [delivery_rates.last]), delivery_rates.last.delivery_method.prefixed_id])
      end
    end

    # PayPal's options are one list for the whole order.
    context 'when the cart is split across two fulfillments' do
      before do
        create(:fulfillment, cart: cart, order: nil, tracking: nil)
        cart.fulfillments.reset
      end

      it 'offers no options' do
        expect(subject.shipping_options).to eq([])
      end
    end

    it 'offers no options to an order that is not express' do
      expect(described_class.new(cart).shipping_options).to eq([])
    end

    it 'leaves the address on an order that is not express' do
      expect(described_class.new(cart).to_json['body'].purchase_units[0].shipping.address).not_to be_nil
    end
  end
end
