# typed: ignore
# frozen_string_literal: true

module Sequel
  module Privacy
    # Actions provides the DSL methods available inside policy lambdas.
    # When policies are evaluated, they execute in the context of this struct,
    # giving them access to allow, deny, pass, and all methods.
    #
    # Example:
    #   policy :AllowAdmins, ->(actor) {
    #     allow if actor.is_role?(:admin)
    #   }
    Actions = (Struct.new do
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
      end).new
  end
end
