# typed: true
# frozen_string_literal: true

module Sequel
  module Privacy
    # A Policy wraps a Proc/lambda with metadata about how it should be evaluated.
    #
    # Policies take 0-3 arguments depending on what context they need:
    # - 0 args: -> { allow }  # Global decision
    # - 1 arg:  ->(actor) { allow if actor.is_role?(:admin) }
    # - 2 args: ->(subject, actor) { allow if subject.owner_id == actor.id }
    # - 3 args: ->(subject, actor, direct_object) { ... }
    #
    # Policies must return :allow, :deny, :pass, or an array of policies (for combinators).
    class Policy < Proc
      extend T::Sig

      sig { returns(T.nilable(String)) }
      attr_reader :policy_name

      sig { returns(T.nilable(String)) }
      attr_reader :comment

      # Factory method for creating policies
      sig do
        params(
          policy_name: Symbol,
          lam: T.proc.returns(Symbol),
          comment: T.nilable(String),
          cacheable: T::Boolean,
          single_match: T::Boolean
        ).returns(T.self_type)
      end
      def self.create(policy_name, lam, comment = nil, cacheable: true, single_match: false)
        new(&lam).setup(
          policy_name: policy_name,
          comment: comment,
          cacheable: cacheable,
          single_match: single_match
        )
      end

      # Configure the policy after creation
      #
      # @param policy_name [Symbol, nil] Human-readable name for logging
      # @param comment [String, nil] Description of what this policy does
      # @param cacheable [Boolean] Whether results can be cached (default: true)
      # @param single_match [Boolean] Whether only one subject/actor pair can match (default: false)
      def setup(policy_name: nil, comment: nil, cacheable: true, single_match: false)
        raise 'Privacy Policy is frozen' if @frozen

        @cacheable = cacheable
        @policy_name = policy_name.to_s
        @comment = comment
        @frozen = true
        @single_match = single_match
        self
      end

      sig { returns(T::Boolean) }
      def cacheable?
        @cacheable || false
      end

      # Single-match optimization: when true, once a policy allows for a subject/actor pair,
      # skip evaluation for other subjects (e.g., AllowIfActorIsSelf - only one subject matches)
      sig { returns(T::Boolean) }
      def single_match?
        @single_match || false
      end
    end
  end
end

# Type aliases for use throughout the gem
module Sequel
  module Privacy
    TPolicy = T.type_alias { Sequel::Privacy::Policy }
    TPolicyArray = T.type_alias { T::Array[T.any(TPolicy, Proc)] }
    TPolicySubject = T.type_alias { T.any(Sequel::Model, T.untyped) }
  end
end
