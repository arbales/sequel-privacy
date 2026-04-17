# typed: true
# frozen_string_literal: true

module Sequel
  module Privacy
    # Actions provides the DSL methods available inside policy lambdas.
    # When policies are evaluated, they execute in the context of this object,
    # giving them access to allow, deny, pass, and all methods.
    #
    # Example:
    #   policy :AllowAdmins, ->(actor) {
    #     allow if actor.is_role?(:admin)
    #   }
    class ActionsClass
      extend T::Sig

      sig { returns(Symbol) }
      def allow
        :allow
      end

      sig { returns(Symbol) }
      def deny
        :deny
      end

      sig { returns(Symbol) }
      def pass
        :pass
      end

      # Combine multiple policies - all must allow for the result to allow.
      # Any deny results in deny. Otherwise passes.
      sig { params(policies: T.untyped).returns(T::Array[T.untyped]) }
      def all(*policies)
        policies
      end

      # Evaluate a policy lambda in the DSL context. Wraps instance_exec so
      # callers don't have to fight Sorbet's strict block-shape signatures
      # for arbitrary-arity policies.
      sig { params(args: T.untyped, blk: Proc).returns(T.untyped) }
      def evaluate(*args, &blk)
        T.unsafe(self).instance_exec(*args, &blk)
      end
    end

    Actions = T.let(ActionsClass.new, ActionsClass)
  end
end
