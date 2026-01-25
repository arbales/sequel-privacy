# typed: true
# Minimal RBI shim for sequel-privacy gem
#
# Most types are defined in the gem source files (typed: strict).
# This shim only provides declarations for:
# 1. Actions - defined in typed: ignore file
# 2. DatasetMethods#model - inherited from Sequel::Dataset
# 3. InstanceMethods @viewer_context - ivar declaration for mixin

module Sequel
  module Privacy
    # Actions is a Struct instance used as the binding context for policy
    # evaluation via instance_exec. Defined in actions.rb (typed: ignore).
    class Actions
      extend T::Sig

      sig { returns(Symbol) }
      def allow; end

      sig { returns(Symbol) }
      def deny; end

      sig { returns(Symbol) }
      def pass; end

      sig { params(policies: T.untyped).returns(T::Array[T.untyped]) }
      def all(*policies); end

      # instance_exec with Policy (which extends Proc)
      sig {
        params(
          args: T.untyped,
          block: Policy
        ).returns(T.untyped)
      }
      def self.instance_exec(*args, &block); end
    end
  end

  module Plugins
    module Privacy
      module InstanceMethods
        # Declare the @viewer_context instance variable for the mixin
        sig { returns(T.nilable(Sequel::Privacy::ViewerContext)) }
        attr_accessor :viewer_context
      end

      module DatasetMethods
        # model is inherited from Sequel::Dataset but not visible to Sorbet
        sig { returns(T.class_of(Sequel::Model)) }
        def model; end
      end
    end
  end
end
