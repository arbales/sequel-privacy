# typed: true

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

      sig {
        params(
          args: T.untyped,
          block: Policy
        ).returns(T.untyped)
      }
      def self.instance_exec(*args, &block); end
    end

    class PrivacyDSL
      extend T::Sig

      sig { params(action: Symbol, policies: T.untyped).void }
      def can(action, *policies); end

      sig { params(field_name: Symbol, policies: T.untyped).void }
      def field(field_name, *policies); end

      sig { params(association_name: Symbol, blk: T.proc.void).void }
      def association(association_name, &blk); end
    end
  end

  module Plugins
    module Privacy
      module ClassMethods
        # The privacy block is evaluated in the context of PrivacyDSL
        sig { params(blk: T.proc.bind(Sequel::Privacy::PrivacyDSL).void).void }
        def privacy(&blk); end
      end

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
