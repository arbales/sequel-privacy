# typed: true
# Minimal shims for things Sorbet can't infer from source

module Sequel
  module Plugins
    module Privacy
      module DatasetMethods
        # Inherited from Sequel::Dataset, not visible to Sorbet
        sig { returns(T.class_of(Sequel::Model)) }
        def model; end
      end
    end
  end
end
