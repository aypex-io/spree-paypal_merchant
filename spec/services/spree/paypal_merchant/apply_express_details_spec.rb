# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::ApplyExpressDetails do
  def fixture
    JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join('spec/fixtures/approved_express_paypal_order.json')))
  end

  # The cart's delivery method at a price. Methods outlive the rates, which
  # Spree quotes again whenever the address changes.
  def delivery_method_costing(amount)
    cart.fulfillments.sole.delivery_rates.find_by(cost: amount).delivery_method
  end

  let(:customer) { create(:user) }
  # Delivery at 10.00 (Spree's default, selected) or 15.00, on the cart's one
  # fulfillment. The items are priced as Spree prices them for an address.
  let(:cart) do
    create(:cart_ready_for_delivery, customer: customer).tap do |cart|
      create(:delivery_method, store: cart.store).calculator.tap do |calculator|
        calculator.preferred_amount = 15
        calculator.preferred_currency = cart.currency
        calculator.save!
      end
      cart.recalculate_for_address_change!(keep_selection: true)
    end
  end
  let(:standard_delivery) { delivery_method_costing(10) }
  let(:express_delivery) { delivery_method_costing(15) }
  # PayPal's order once the buyer approved it, having chosen the 15.00
  # delivery. The gem keyed each option on its delivery method.
  let(:paypal_order) do
    fixture.tap do |data|
      standard, express = data['purchase_units'][0]['shipping']['options']
      standard['id'] = standard_delivery.prefixed_id
      express['id'] = express_delivery.prefixed_id
    end
  end

  def apply
    described_class.new(owner: cart, paypal_order: paypal_order).call
  end

  describe '#call' do
    let(:written) do
      {
        'first_name' => 'Ada', 'last_name' => 'Lovelace', 'address1' => '1 Example Way', 'address2' => 'Suite 100',
        'city' => 'Los Angeles', 'postal_code' => '90012', 'country_code' => 'US', 'phone' => '2135550123', 'quick_checkout' => false
      }
    end

    # Spree stores a quick_checkout of false as NULL, so it is read as a predicate.
    def full_address_fields(address)
      address.attributes.slice(*written.keys).merge('quick_checkout' => address.quick_checkout?)
    end

    # What a write changes: the address rows the cart points at, the street,
    # and the delivery rate it has selected (rates are recreated by a quote).
    def cart_state
      cart.reload
      [cart.ship_address_id, cart.bill_address_id, cart.ship_address.address1, cart.fulfillments.sole.selected_delivery_rate]
    end

    shared_examples "writing PayPal's details" do
      it "writes PayPal's name and address as the full ship and bill address" do
        apply
        cart.reload

        expect([cart.ship_address, cart.bill_address].map { |address| full_address_fields(address) }).to eq([written, written])
      end

      # Two confirms of one PayPal order, or a retry, find the details written.
      it 'changes nothing when it runs again' do
        apply

        expect { apply }.not_to(change { [Spree::Address.count, cart_state] })
      end

      it 'keeps the delivery chosen in PayPal when it runs again' do
        2.times { apply }

        expect(cart.reload.fulfillments.sole.selected_delivery_rate.delivery_method).to eq(express_delivery)
      end

      # The address and the delivery are written together or not at all, so
      # nobody sees the cart with PayPal's address and Spree's default delivery.
      it 'leaves the cart as it was when it refuses' do
        paypal_order['purchase_units'][0]['shipping']['options'][1]['id'] = 'dm_withdrawn'
        before_refusal = cart_state

        expect { apply }.to raise_error(Spree::Core::GatewayError)

        expect(cart_state).to eq(before_refusal)
      end
    end

    it_behaves_like "writing PayPal's details"

    # A guest's cart edits its address row in place until the bill address
    # shares it; after that, each write makes a new row.
    context 'when the cart belongs to a guest' do
      let(:customer) { nil }

      it_behaves_like "writing PayPal's details"
    end

    # PayPal sends the region as the buyer's PayPal account names it.
    it 'resolves a region name to its code' do
      apply

      expect(cart.reload.ship_address.state_code).to eq('CA')
    end

    it 'sets the email from PayPal when the cart has none' do
      cart.update_columns(email: nil) # rubocop:disable Rails/SkipsModelValidations

      apply

      expect(cart.reload.email).to eq('ada.lovelace@example.com')
    end

    it 'keeps an email the cart already has' do
      apply

      expect(cart.reload.email).to eq('buyer@example.com')
    end

    it "takes a part of the name PayPal's shipping name lacks from the payer" do
      paypal_order['purchase_units'][0]['shipping']['name']['full_name'] = 'Ada'

      apply

      expect(cart.reload.ship_address.attributes.slice('first_name', 'last_name')).to eq('first_name' => 'Ada', 'last_name' => 'Lovelace')
    end

    # The new address puts the delivery back to Spree's default.
    it 're-selects the delivery chosen in PayPal' do
      apply
      cart.reload

      expect([cart.fulfillments.sole.selected_delivery_rate.delivery_method, cart.delivery_total, cart.total])
        .to eq([express_delivery, 15, cart.item_total + 15])
    end

    it 'refuses when the chosen delivery is no longer offered' do
      paypal_order['purchase_units'][0]['shipping']['options'][1]['id'] = 'dm_withdrawn'

      expect { apply }.to raise_error(Spree::Core::GatewayError, 'The delivery chosen in PayPal is not available for this address')
    end

    # The breakdown could not carry the options, so PayPal offered no choice.
    it "keeps Spree's delivery when PayPal offered no choice" do
      paypal_order['purchase_units'][0]['shipping'].delete('options')

      apply

      expect(cart.reload.fulfillments.sole.selected_delivery_rate.delivery_method).to eq(standard_delivery)
    end

    it 'refuses an address Spree does not accept' do
      paypal_order['purchase_units'][0]['shipping']['address']['postal_code'] = 'not a ZIP'

      expect { apply }.to raise_error(Spree::Core::GatewayError, /postal code/i)
    end
  end
end
