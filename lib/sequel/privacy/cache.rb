# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # In-memory cache for policy evaluation results.
    # Should be cleared between requests (e.g., via Rack middleware).
    class << self
      extend T::Sig

      # Returns the in-memory cache Hash for policy results.
      sig { returns(T::Hash[Integer, Symbol]) }
      def cache
        @cache ||= T.let({}, T.nilable(T::Hash[Integer, Symbol]))
      end

      # Returns the hash tracking single-match optimizations.
      # Key: [policy, actor, viewer_context].hash
      # Value: subject.hash that matched
      sig { returns(T::Hash[Integer, Integer]) }
      def single_matches
        @single_matches ||= T.let({}, T.nilable(T::Hash[Integer, Integer]))
      end

      # Clear all caches. Call this between requests.
      sig { void }
      def clear_cache!
        @cache = {}
        @single_matches = {}
      end
    end
  end
end
