# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # Represents who is viewing/accessing data. All privacy checks require
    # a ViewerContext.
    class ViewerContext
      extend T::Sig
      extend T::Helpers
      abstract!

      sig { params(actor: IActor).returns(ActorVC) }
      def self.for_actor(actor)
        ActorVC.new(actor)
      end

      sig { params(actor: IActor).returns(APIVC) }
      def self.for_api_actor(actor)
        APIVC.new(actor)
      end

      # Bypasses all privacy checks; requires a reason for audit logging.
      # Use sparingly.
      sig { params(reason: Symbol).returns(AllPowerfulVC) }
      def self.all_powerful(reason)
        Sequel::Privacy.logger&.info("Creating all-powerful viewer context: #{reason}")
        AllPowerfulVC.new(reason)
      end

      # Reads any record but cannot mutate. For system operations like
      # authentication lookups.
      sig { params(reason: Symbol).returns(OmniscientVC) }
      def self.omniscient(reason)
        Sequel::Privacy.logger&.debug("Creating omniscient viewer context: #{reason}")
        OmniscientVC.new(reason)
      end

      # No actor; subject to normal policy evaluation. For logged-out users.
      sig { returns(AnonymousVC) }
      def self.anonymous
        AnonymousVC.new
      end

      sig { returns(T::Boolean) }
      def invalidated?
        @invalidated = T.let(@invalidated, T.nilable(T::Boolean))
        @invalidated || false
      end

      sig { void }
      def assert_usable!
        return unless invalidated?

        Kernel.raise InvalidatedViewerContext,
                     "#{self.class.name.to_s.split('::').last} was invalidated and cannot be used again"
      end
    end

    # Made available on OmniscientVC and AllPowerfulVCs. Transient contexts are
    # invalidated when the use block exists. To help you keep these around for
    # as short a time as possible.
    module TransientViewerContext
      extend T::Sig
      extend T::Helpers

      abstract!
      requires_ancestor { ViewerContext }

      sig { abstract.returns(Symbol) }
      def reason; end

      sig do
        type_parameters(:U)
          .params(block: T.proc.params(vc: T.untyped, reason: Symbol).returns(T.type_parameter(:U)))
          .returns(T.type_parameter(:U))
      end
      def use(&block)
        block.call(self, reason)
      ensure
        invalidate!
      end

      sig { returns(T.self_type) }
      def invalidate!
        unless invalidated?
          Sequel::Privacy.logger&.debug("Invalidating viewer context: #{reason}")
          @invalidated = T.let(true, T.nilable(T::Boolean))
        end
        self
      end
    end

    # Standard viewer context with an actor (user/member)
    class ActorVC < ViewerContext
      extend T::Sig

      sig { params(actor: IActor).void }
      def initialize(actor)
        @actor = T.let(actor, IActor)
        super()
      end

      sig { returns(IActor) }
      attr_reader :actor
    end

    # API-specific viewer context (same as ActorVC but can be distinguished)
    class APIVC < ActorVC; end

    # All-powerful viewer context that bypasses all privacy checks.
    # Used for admin operations, background jobs, etc.
    # Requires a reason for audit logging.
    class AllPowerfulVC < ViewerContext
      extend T::Sig
      include TransientViewerContext

      sig { params(reason: Symbol).void }
      def initialize(reason)
        @reason = T.let(reason, Symbol)
        super()
      end

      sig { override.returns(Symbol) }
      attr_reader :reason
    end

    # Omniscient viewer context that can see everything but cannot mutate.
    # Used for system operations like authentication lookups.
    class OmniscientVC < ViewerContext
      extend T::Sig
      include TransientViewerContext

      sig { params(reason: Symbol).void }
      def initialize(reason)
        @reason = T.let(reason, Symbol)
        super()
      end

      sig { override.returns(Symbol) }
      attr_reader :reason
    end

    class AnonymousVC < ViewerContext
      extend T::Sig

      sig { void }
      def initialize
        super()
      end
    end

    TViewerContext = T.type_alias { ViewerContext }
  end
end
