# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'historical SpreePaypalCheckout STI alias' do
  it 'constantizes the old gateway type onto the new class' do
    expect(SpreePaypalCheckout::Gateway).to eq(Spree::PaypalCheckout::Gateway)
  end

  it 'includes the old type string in gateway_type_names' do
    expect(Spree::PaypalCheckout.gateway_type_names).to include('SpreePaypalCheckout::Gateway')
  end
end
