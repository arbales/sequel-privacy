# typed: true
# frozen_string_literal: true

module Sequel
  module Privacy
    # DSL for defining custom policies.
    # Extend your policy module with this to get the `policy` method.
    #
    # Example:
    #   module P
    #     extend Sequel::Privacy::PolicyDSL
    #
    #     AlwaysDeny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny
    #
    #     policy :AllowAdmins, ->(actor) {
    #       allow if actor.is_role?(:admin)
    #     }, 'Allow admin users', cacheable: true
    #   end
    module PolicyDSL
      extend T::Sig
      extend T::Helpers

      # PolicyDSL is meant to be `extend`ed onto another Module, so `self`
      # at runtime is always a Module that responds to `const_set`.
      requires_ancestor { Module }

      # Define a new policy constant on the extending module.
      #
      # @param name [Symbol] The policy name (will become a constant)
      # @param lam [Proc] The policy lambda (0-3 args: actor, subject, direct_object)
      # @param comment [String, nil] Human-readable description
      # @param cacheable [Boolean] Whether results can be cached (default: true)
      # @param single_match [Boolean] Whether only one subject/actor can match (default: false)
      sig do
        params(
          name: Symbol,
          lam: Proc,
          comment: T.nilable(String),
          cacheable: T::Boolean,
          single_match: T::Boolean
        ).void
      end
      def policy(name, lam, comment = nil, cacheable: true, single_match: false)
        p = Policy.new(&lam).setup(
          policy_name: name,
          comment: comment,
          cacheable: cacheable,
          single_match: single_match
        )
        const_set(name, p)
      end
    end
  end
end
