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

      sig { params(reason: Symbol).void }
      def initialize(reason)
        @reason = T.let(reason, Symbol)
        super()
      end

      sig { returns(Symbol) }
      attr_reader :reason
    end

    # Omniscient viewer context that can see everything but cannot mutate.
    # Used for system operations like authentication lookups.
    class OmniscientVC < ViewerContext
      extend T::Sig

      sig { params(reason: Symbol).void }
      def initialize(reason)
        @reason = T.let(reason, Symbol)
        super()
      end

      sig { returns(Symbol) }
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
