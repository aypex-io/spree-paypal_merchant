# frozen_string_literal: true

module Spree
  module PaypalPlatform
    ##
    # Abstract ActiveRecord base for this gem's persisted models.
    #
    # Table names resolve through {Spree::PaypalPlatform.table_name_prefix}.
    #
    class Base < ::Spree.base_class
      self.abstract_class = true
    end
  end
end
