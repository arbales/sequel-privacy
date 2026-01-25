# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # The Enforcer evaluates policy chains to determine if an action is allowed.
    # It handles caching, single-match optimization, and policy combinators.
    module Enforcer
      extend T::Sig

      class << self
        extend T::Sig

        # Returns the centralized logger from Sequel::Privacy.logger
        sig { returns(T.untyped) }
        def logger
          Sequel::Privacy.logger
        end
      end

      # Main entry point for policy evaluation.
      #
      # @param policies [Array<Policy, Proc>] The policy chain to evaluate
      # @param subject [Sequel::Model] The object being accessed
      # @param viewer_context [ViewerContext] Who is accessing the object
      # @param direct_object [Sequel::Model, nil] Optional additional context object
      # @return [Boolean] true if access is allowed, false otherwise
      sig do
        params(
          policies: TPolicyArray,
          subject: TPolicySubject,
          viewer_context: TViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(T::Boolean)
      end
      def self.enforce(policies, subject, viewer_context, direct_object = nil)
        # All-powerful contexts bypass all checks
        if viewer_context.is_a?(AllPowerfulVC)
          logger&.warn('BYPASS: All-powerful viewer context bypasses all privacy rules.')
          return true
        end

        actor = T.cast(viewer_context, ActorVC).actor

        # Ensure we have policies to evaluate
        if policies.empty?
          logger&.error { "No policies for #{subject.class}[#{subject_id(subject)}]. Denying by default." }
          policies = [BuiltInPolicies::AlwaysDeny]
        end

        # Ensure policy chain ends with AlwaysDeny (fail-secure)
        unless policies.last == BuiltInPolicies::AlwaysDeny
          logger&.warn { 'Policy chain should end with AlwaysDeny. Appending it.' }
          policies = policies.dup << BuiltInPolicies::AlwaysDeny
        end

        # Evaluate policies in order
        policies.each do |uncasted_policy|
          result = policy_result(uncasted_policy, subject, actor, viewer_context, direct_object)
          return true if result == :allow
          return false if result == :deny
        end

        false
      end

      # Compute cache key based on policy arity
      sig do
        params(
          policy: Policy,
          subject: TPolicySubject,
          actor: IActor,
          viewer_context: ViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(Integer)
      end
      def self.compute_cache_key(policy, subject, actor, viewer_context, direct_object)
        case policy.arity
        when 0
          [policy, viewer_context].hash
        when 1
          [policy, actor, viewer_context].hash
        when 2
          [policy, subject, actor, viewer_context].hash
        else
          [policy, subject, actor, direct_object, viewer_context].hash
        end
      end

      sig { params(outcome: Symbol).returns(T::Boolean) }
      def self.valid_outcome?(outcome)
        %i[allow pass deny].include?(outcome)
      end

      # Evaluate a combinator (array of policies returned by `all()`)
      # All must allow for the result to be :allow, any :deny results in :deny
      sig do
        params(
          child_policies: TPolicyArray,
          subject: TPolicySubject,
          actor: IActor,
          viewer_context: ViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(Symbol)
      end
      def self.evaluate_child_policies(child_policies, subject, actor, viewer_context, direct_object)
        unless child_policies.all? { |c| c.is_a?(Proc) }
          Kernel.raise "Policy combinator contains non-policy members"
        end

        results = child_policies.map do |child_policy|
          policy_result(child_policy, subject, actor, viewer_context, direct_object)
        end

        return :deny if results.include?(:deny)
        return :allow if results.all? { |r| r == :allow }

        :pass
      end

      # Evaluate a single policy and return its result
      sig do
        params(
          uncasted_policy: T.any(TPolicy, Proc),
          subject: TPolicySubject,
          actor: IActor,
          viewer_context: ViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(Symbol)
      end
      def self.policy_result(uncasted_policy, subject, actor, viewer_context, direct_object)
        from_cache = false
        skipped_from_single_match = false

        policy = T.cast(uncasted_policy, TPolicy, checked: false)

        # Single-match optimization
        if policy.single_match?
          match_key = [policy, actor, viewer_context].hash
          if (matched = Sequel::Privacy.single_matches[match_key]) && matched != subject.hash
            skipped_from_single_match = true
            result = :pass
          end
        end

        # Check cache
        cache_key = compute_cache_key(policy, subject, actor, viewer_context, direct_object)
        if !skipped_from_single_match && policy.cacheable? && Sequel::Privacy.cache.key?(cache_key)
          from_cache = true
          result = Sequel::Privacy.cache[cache_key]
          Kernel.raise InvalidPolicyOutcomeError unless result && valid_outcome?(result)
        end

        # Execute policy if not cached
        result ||= execute_policy(policy, subject, actor, direct_object)
        result ||= :pass

        # Handle combinator results
        if result.is_a?(Array)
          result = evaluate_child_policies(result, subject, actor, viewer_context, direct_object)
        end

        # Cache result
        if policy.cacheable? && !from_cache
          Sequel::Privacy.cache[cache_key] = result
        end

        # Log result
        log_result(policy, result, actor, subject, from_cache, skipped_from_single_match)

        # Record single-match
        if policy.single_match? && result == :allow
          Sequel::Privacy.single_matches[[policy, actor, viewer_context].hash] = subject.hash
        end

        unless valid_outcome?(result)
          Kernel.raise InvalidPolicyOutcomeError, "Policy returned #{result.inspect}, expected :allow, :deny, or :pass"
        end

        result
      end

      sig do
        params(
          policy: Policy,
          subject: TPolicySubject,
          actor: IActor,
          direct_object: T.nilable(Sequel::Model)
        ).returns(T.untyped)
      end
      def self.execute_policy(policy, subject, actor, direct_object)
        case policy.arity
        when 0
          Actions.instance_exec(&policy)
        when 1
          Actions.instance_exec(actor, &policy)
        when 2
          Actions.instance_exec(subject, actor, &policy)
        else
          Actions.instance_exec(subject, actor, direct_object, &policy)
        end
      end

      sig do
        params(
          policy: Policy,
          result: Symbol,
          actor: IActor,
          subject: TPolicySubject,
          from_cache: T::Boolean,
          skipped: T::Boolean
        ).void
      end
      def self.log_result(policy, result, actor, subject, from_cache, skipped)
        return unless logger

        logger.debug do
          msg = "#{result.to_s.upcase}: #{policy.policy_name || 'anonymous'} for actor[#{actor.id}] on #{subject.class}[#{subject_id(subject)}]"
          msg += " (cached)" if from_cache
          msg += " (skipped: single_match)" if skipped
          msg
        end

        if policy.comment && %i[deny allow].include?(result)
          logger.debug { " ⮑  #{policy.comment}" }
        end
      end

      sig { params(subject: TPolicySubject).returns(T.untyped) }
      def self.subject_id(subject)
        subject.respond_to?(:pk) ? subject.pk : subject.object_id
      end
    end
  end
end
