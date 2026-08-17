# frozen_string_literal: true

module Spree
  module PaypalCheckout
    module Generators
      ##
      # Copies this gem's migrations into the host app and optionally runs them.
      #
      class InstallGenerator < Rails::Generators::Base
        desc 'Copies Spree::PaypalCheckout migrations into the host application and runs them.'

        class_option :auto_run_migrations,
                     type: :boolean,
                     default: false,
                     desc: 'Run the copied migrations immediately instead of asking'

        def copy_migrations
          rake 'spree_paypal_checkout:install:migrations'
        end

        def run_migrations
          if run_migrations?
            rake 'db:migrate'
          else
            say_status :skip, 'db:migrate — remember to run it before using the gem', :yellow
          end
        end

        private

        def run_migrations?
          return true if options[:auto_run_migrations]

          ask('Run the migrations now? [Yn]').to_s.strip.casecmp('n') != 0
        end
      end
    end
  end
end
