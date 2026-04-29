# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # In-memory cache for policy evaluation results. Clear between
    # requests (e.g. via Rack middleware).
    class << self
      extend T::Sig

      sig { returns(T::Hash[Integer, Symbol]) }
      def cache
        @cache ||= T.let({}, T.nilable(T::Hash[Integer, Symbol]))
      end

      # Tracks single-match optimization state.
      # Key: [policy, actor, viewer_context].hash → Value: subject.hash
      sig { returns(T::Hash[Integer, Integer]) }
      def single_matches
        @single_matches ||= T.let({}, T.nilable(T::Hash[Integer, Integer]))
      end

      sig { void }
      def clear_cache!
        @cache = {}
        @single_matches = {}
      end
    end
  end
end
