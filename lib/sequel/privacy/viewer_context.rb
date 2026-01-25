# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # ViewerContext represents who is viewing/accessing data.
    # All privacy checks require a viewer context to determine what the viewer can see.
    class ViewerContext
      extend T::Sig
      extend T::Helpers
      abstract!

      # Create a standard viewer context for an actor
      sig { params(actor: IActor).returns(ActorVC) }
      def self.for_actor(actor)
        ActorVC.new(actor)
      end

      # Create an API-specific viewer context
      sig { params(actor: IActor).returns(APIVC) }
      def self.for_api_actor(actor)
        APIVC.new(actor)
      end

      # Create an all-powerful viewer context that bypasses all privacy checks.
      # Use sparingly and always provide a reason for audit logging.
      sig { params(reason: String).returns(AllPowerfulVC) }
      def self.all_powerful(reason)
        Sequel::Privacy.logger&.info("Creating all-powerful viewer context: #{reason}")
        AllPowerfulVC.new(reason)
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

      sig { params(reason: String).void }
      def initialize(reason)
        @reason = T.let(reason, String)
        super()
      end

      sig { returns(String) }
      attr_reader :reason
    end

    # Internal policy evaluation viewer context.
    # Used internally during policy evaluation to allow raw association access
    # without triggering recursive privacy checks. For example, when checking
    # "is actor a member of this list?", we need to access list.members without
    # filtering those members by their own :view policies.
    #
    # This class is internal to the privacy plugin and should not be used directly.
    class InternalPolicyEvaluationVC < ViewerContext
      extend T::Sig

      sig { void }
      def initialize
        super()
      end
    end

    # Type alias for viewer contexts
    TViewerContext = T.type_alias { ViewerContext }
  end
end
