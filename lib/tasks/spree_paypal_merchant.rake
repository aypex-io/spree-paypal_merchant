# frozen_string_literal: true

namespace :spree do
  namespace :paypal_merchant do
    desc "Record in Spree the refunds made in PayPal for an order's PayPal payments, e.g. before the webhook was set up"
    task :sync_refunds, [:order_number] => :environment do |_task, args|
      order_number = args[:order_number].to_s.strip
      abort "Usage: bin/rails 'spree:paypal_merchant:sync_refunds[<order number>]'" if order_number.empty?

      order = Spree::Order.find_by(number: order_number)
      abort "No order #{order_number}" if order.nil?

      Spree::Current.store = order.store
      payments = order.payments.order(:id).select { |payment| payment.payment_method.is_a?(Spree::PaypalMerchant::Gateway) }
      puts "Order #{order_number} has no PayPal payments." if payments.empty?

      payments.each do |payment|
        result = Spree::PaypalMerchant::SyncRefunds.new(payment: payment).call

        puts "Payment #{payment.number}:"
        result.recorded.each { |refund| puts "  recorded PayPal refund #{refund.transaction_id} (#{refund.display_amount})" }
        result.skipped.each { |message| puts "  #{message}" }
        puts '  no PayPal refunds' if result.recorded.empty? && result.skipped.empty?
      rescue Spree::PaypalMerchant::SyncRefunds::RefundInProgress, Spree::PaypalMerchant::SyncRefunds::PaypalUnavailable,
             Spree::Core::GatewayError => e
        puts "Payment #{payment.number}: not synced: #{e.message}"
      end
    end
  end
end
