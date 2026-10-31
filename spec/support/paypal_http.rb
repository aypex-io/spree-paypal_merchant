# frozen_string_literal: true

##
# PayPal's REST API stubbed at the HTTP level, so the gem's own SDK client
# reads the hand-written fixtures as it would read PayPal. The gateways in
# these specs use sandbox credentials.
#
module PaypalHttp
  PAYPAL_API = 'https://api-m.sandbox.paypal.com'

  ##
  # Any refund request sent to PayPal, for any capture.
  #
  REFUND_REQUEST = %r{\A#{Regexp.escape(PAYPAL_API)}/v2/payments/captures/[^/]+/refund\z}

  def paypal_fixture(name)
    JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join("spec/fixtures/#{name}.json")))
  end

  def stub_paypal_token
    stub_request(:post, "#{PAYPAL_API}/v1/oauth2/token")
      .to_return(paypal_json({ access_token: 'A21AA-TEST-TOKEN', token_type: 'Bearer', expires_in: 32_400 }))
  end

  def stub_paypal_order(paypal_order)
    stub_request(:get, "#{PAYPAL_API}/v2/checkout/orders/#{paypal_order['id']}").to_return(paypal_json(paypal_order))
  end

  def stub_paypal_capture(paypal_capture)
    stub_request(:get, "#{PAYPAL_API}/v2/payments/captures/#{paypal_capture['id']}").to_return(paypal_json(paypal_capture))
  end

  ##
  # Answers any refund request, so a spec that asserts none was sent fails on
  # the assertion rather than on WebMock refusing the request.
  #
  def stub_paypal_refund_requests
    stub_request(:post, REFUND_REQUEST)
      .to_return(paypal_json({ id: 'REFUND-SENT-BY-SPEC', status: 'COMPLETED', amount: { currency_code: 'USD', value: '1.00' } }))
  end

  def paypal_json(body, status: 200)
    { status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end
end
