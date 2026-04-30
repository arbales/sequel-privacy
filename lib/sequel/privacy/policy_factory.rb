# typed: true
# frozen_string_literal: true

module Sequel
  module Privacy
    # A PolicyFactory captures definition-time arguments and returns concrete
    # Policy instances that can be registered in a privacy policy chain.
    class PolicyFactory
      extend T::Sig

      sig { returns(String) }
      attr_reader :factory_name

      sig do
        params(
          factory_name: Symbol,
          factory: Proc,
          comment: T.nilable(String),
          cacheable: T::Boolean,
          single_match: T::Boolean,
          cache_by: T.nilable(T.any(Symbol, T::Array[Symbol])),
          allow_anonymous: T::Boolean
        ).void
      end
      def initialize(factory_name, factory, comment: nil, cacheable: true, single_match: false, cache_by: nil,
                     allow_anonymous: false)
        @factory_name = T.let(factory_name.to_s, String)
        @factory = T.let(factory, Proc)
        @comment = T.let(comment, T.nilable(String))
        @cacheable = T.let(cacheable, T::Boolean)
        @single_match = T.let(single_match, T::Boolean)
        @cache_by = T.let(cache_by, T.nilable(T.any(Symbol, T::Array[Symbol])))
        @allow_anonymous = T.let(allow_anonymous, T::Boolean)
      end

      sig { params(args: T.untyped).returns(Policy) }
      def call(*args)
        lam = T.unsafe(@factory).call(*args)
        unless lam.is_a?(Proc)
          Kernel.raise ArgumentError,
                       "Policy factory #{@factory_name} must return a Proc, got #{lam.inspect}"
        end

        T.cast(
          Policy.create(
            policy_name_for(args),
            lam,
            @comment,
            cacheable: @cacheable,
            single_match: @single_match,
            cache_by: @cache_by,
            allow_anonymous: @allow_anonymous
          ),
          Policy
        )
      end

      private

      sig { params(args: T::Array[T.untyped]).returns(Symbol) }
      def policy_name_for(args)
        return @factory_name.to_sym if args.empty?

        :"#{@factory_name}(#{args.map(&:inspect).join(', ')})"
      end
    end
  end
end
