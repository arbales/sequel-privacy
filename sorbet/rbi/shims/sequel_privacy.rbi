# typed: true
# Minimal shims for things Sorbet can't infer from source

module Sequel
  module Privacy
    # Actions is a Struct instance defined in actions.rb (typed: ignore)
    class Actions
      sig { returns(Symbol) }
      def allow; end

      sig { returns(Symbol) }
      def deny; end

      sig { returns(Symbol) }
      def pass; end

      sig { params(policies: T.untyped).returns(T::Array[T.untyped]) }
      def all(*policies); end

      sig { params(args: T.untyped, block: T.untyped).returns(T.untyped) }
      def self.instance_exec(*args, &block); end
    end
  end

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
