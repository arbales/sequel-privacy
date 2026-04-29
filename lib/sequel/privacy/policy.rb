# typed: true
# frozen_string_literal: true

module Sequel
  module Privacy
    # A Policy wraps a Proc/lambda with metadata about how it should be evaluated.
    #
    # Policies are actor-first. Arities map to:
    # - 0 args: -> { allow if Time.now.sunday? }     # Global decision
    # - 1 arg:  ->(actor) { allow if actor.is_role?(:admin) }
    # - 2 args: ->(actor, subject) { allow if subject.owner_id == actor.id }
    # - 3 args: ->(actor, subject, direct_object) { ... }
    #
    # Any policy with arity >= 1 auto-denies for anonymous viewers (nil actor)
    # unless declared with `allow_anonymous: true`. That flag is for state-gate
    # policies that deliberately ignore actor — e.g. "post is published."
    #
    # Policies must return :allow, :deny, :pass, or an array of policies (for combinators).
    class Policy < Proc
      extend T::Sig

      sig { returns(T.nilable(String)) }
      attr_reader :policy_name

      sig { returns(T.nilable(String)) }
      attr_reader :comment

      VALID_CACHE_BY = T.let(%i[actor subject direct_object].freeze, T::Array[Symbol])

      sig do
        params(
          policy_name: Symbol,
          lam: Proc,
          comment: T.nilable(String),
          cacheable: T::Boolean,
          single_match: T::Boolean,
          cache_by: T.nilable(T.any(Symbol, T::Array[Symbol])),
          allow_anonymous: T::Boolean
        ).returns(T.self_type)
      end
      def self.create(policy_name, lam, comment = nil, cacheable: true, single_match: false, cache_by: nil,
                      allow_anonymous: false)
        new(&lam).setup(
          policy_name: policy_name,
          comment: comment,
          cacheable: cacheable,
          single_match: single_match,
          cache_by: cache_by,
          allow_anonymous: allow_anonymous
        )
      end

      # Configure the policy after creation, normally done with the shorthand `policy` call.
      #
      # @param policy_name [Symbol, nil] Human-readable name for logging
      # @param comment [String, nil] Description of what this policy does
      # @param cacheable [Boolean] Whether results can be cached (default: true)
      # @param single_match [Boolean] Whether only one subject/actor pair can match (default: false)
      # @param cache_by [Symbol, Array<Symbol>, nil] Override the cache-key
      #   dimensions. By default the key is derived from the policy's arity,
      #   but you might want to pass a subset of `:actor, :subject, :direct_object` 
      #   to cache by only those; useful when the policy ignores inputs (e.g. an
      #   "is-admin" check that takes `(actor, subject)` but only looks at
      #   actor should use `cache_by: :actor` to share a single entry across
      #   subjects).
      # @param allow_anonymous [Boolean] If true, skip the auto-deny that
      #   normally fires when a policy of arity >= 1 is evaluated for an
      #   anonymous viewer (nil actor). This is a bit inelegant; it'd be great
      #   if we could tell that an argument isn't used at all. 
      def setup(policy_name: nil, comment: nil, cacheable: true, single_match: false, cache_by: nil,
                allow_anonymous: false)
        raise 'Privacy Policy is frozen' if @frozen

        @cacheable = cacheable
        @policy_name = policy_name.to_s
        @comment = comment
        @frozen = true
        @single_match = single_match
        @cache_by = normalize_cache_by(cache_by)
        @allow_anonymous = allow_anonymous
        self
      end

      sig { returns(T::Boolean) }
      def cacheable?
        @cacheable || false
      end

      # When set, once the policy allows for a given actor it short-circuits
      # to :pass on every other subject — useful when only one subject can
      # ever match (e.g. AllowSelf).
      sig { returns(T::Boolean) }
      def single_match?
        @single_match || false
      end

      sig { returns(T.nilable(T::Array[Symbol])) }
      def cache_by
        @cache_by
      end

      sig { returns(T::Boolean) }
      def allow_anonymous?
        @allow_anonymous || false
      end

      private

      sig { params(val: T.nilable(T.any(Symbol, T::Array[Symbol]))).returns(T.nilable(T::Array[Symbol])) }
      def normalize_cache_by(val)
        return nil if val.nil?

        keys = Array(val).map(&:to_sym)
        invalid = keys - VALID_CACHE_BY
        unless invalid.empty?
          raise ArgumentError,
                "Invalid cache_by key(s): #{invalid.inspect}. Valid keys: #{VALID_CACHE_BY.inspect}"
        end

        keys
      end
    end
  end
end

module Sequel
  module Privacy
    TPolicy = T.type_alias { Sequel::Privacy::Policy }
    TPolicyArray = T.type_alias { T::Array[T.any(TPolicy, Proc)] }
    TPolicySubject = T.type_alias { T.any(Sequel::Model, T.untyped) }
  end
end
