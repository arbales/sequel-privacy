# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    module Enforcer
      extend T::Sig

      # Thread-local flag set while a policy chain is being evaluated.
      # Implicit :view enforcement (Model.call, field readers, association
      # readers) checks this flag and returns raw data when set, so policies
      # can traverse protected fields and associations without recursive
      # filtering. Explicit `allow?` calls always run regardless.
      EVAL_KEY = :sequel_privacy_in_policy_eval

      class << self
        extend T::Sig

        sig { returns(T.untyped) }
        def logger
          Sequel::Privacy.logger
        end
      end

      sig { returns(T::Boolean) }
      def self.in_policy_eval?
        Thread.current[EVAL_KEY] == true
      end

      # Evaluates a policy chain against (subject, viewer_context, direct_object)
      # and returns whether access is allowed.
      sig do
        params(
          policies: TPolicyArray,
          subject: TPolicySubject,
          viewer_context: TViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(T::Boolean)
      end
      def self.enforce(policies, subject, viewer_context, direct_object = nil)
        viewer_context.assert_usable!

        saved = Thread.current[EVAL_KEY]
        Thread.current[EVAL_KEY] = true

        begin
          if viewer_context.is_a?(AllPowerfulVC)
            logger&.warn('BYPASS: All-powerful viewer context bypasses all privacy rules.')
            return true
          end

          if viewer_context.is_a?(OmniscientVC)
            logger&.debug { "BYPASS: Omniscient viewer context (#{viewer_context.reason})" }
            return true
          end

          actor = viewer_context.is_a?(ActorVC) ? viewer_context.actor : nil

          if policies.empty?
            logger&.error { "No policies for #{subject.class}[#{subject_id(subject)}]. Denying by default." }
            policies = [BuiltInPolicies::AlwaysDeny]
          end

          # Fail-secure: every chain ends with AlwaysDeny.
          unless policies.last == BuiltInPolicies::AlwaysDeny
            logger&.debug { 'Policy chain should end with AlwaysDeny. Appending it.' }
            policies = policies.dup << BuiltInPolicies::AlwaysDeny
          end

          policies.each do |uncasted_policy|
            result = policy_result(uncasted_policy, subject, actor, viewer_context, direct_object)
            return true if result == :allow
            return false if result == :deny
          end

          false
        ensure
          Thread.current[EVAL_KEY] = saved
        end
      end

      # Compute cache key based on policy arity
      sig do
        params(
          policy: Policy,
          subject: TPolicySubject,
          actor: T.nilable(IActor),
          viewer_context: ViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(Integer)
      end
      def self.compute_cache_key(policy, subject, actor, viewer_context, direct_object)
        if (keys = policy.cache_by)
          parts = T.let([policy, viewer_context], T::Array[T.untyped])
          keys.each do |k|
            parts << case k
                     when :actor then actor
                     when :subject then subject
                     when :direct_object then direct_object
                     end
          end
          return parts.hash
        end

        case policy.arity
        when 0
          [policy, viewer_context].hash
        when 1
          [policy, actor, viewer_context].hash
        when 2
          [policy, actor, subject, viewer_context].hash
        else
          [policy, actor, subject, direct_object, viewer_context].hash
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
          actor: T.nilable(IActor),
          viewer_context: ViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(Symbol)
      end
      def self.evaluate_child_policies(child_policies, subject, actor, viewer_context, direct_object)
        Kernel.raise 'Policy combinator contains non-policy members' unless child_policies.all? { |c| c.is_a?(Proc) }

        results = child_policies.map do |child_policy|
          policy_result(child_policy, subject, actor, viewer_context, direct_object)
        end

        return :deny if results.include?(:deny)
        return :allow if results.all? { |r| r == :allow }

        :pass
      end

      sig do
        params(
          uncasted_policy: T.any(TPolicy, Proc),
          subject: TPolicySubject,
          actor: T.nilable(IActor),
          viewer_context: ViewerContext,
          direct_object: T.nilable(Sequel::Model)
        ).returns(Symbol)
      end
      def self.policy_result(uncasted_policy, subject, actor, viewer_context, direct_object)
        from_cache = false
        skipped_from_single_match = false

        policy = T.cast(uncasted_policy, TPolicy, checked: false)

        if policy.single_match?
          match_key = [policy, actor, viewer_context].hash
          if (matched = Sequel::Privacy.single_matches[match_key]) && matched != subject.hash
            skipped_from_single_match = true
            result = :pass
          end
        end

        cache_key = compute_cache_key(policy, subject, actor, viewer_context, direct_object)
        if !skipped_from_single_match && policy.cacheable? && Sequel::Privacy.cache.key?(cache_key)
          from_cache = true
          result = Sequel::Privacy.cache[cache_key]
          Kernel.raise InvalidPolicyOutcomeError unless result && valid_outcome?(result)
        end

        result ||= execute_policy(policy, subject, actor, direct_object)
        result ||= :pass

        result = evaluate_child_policies(result, subject, actor, viewer_context, direct_object) if result.is_a?(Array)

        Sequel::Privacy.cache[cache_key] = result if policy.cacheable? && !from_cache

        log_result(policy, result, actor, subject, from_cache, skipped_from_single_match)

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
          actor: T.nilable(IActor),
          direct_object: T.nilable(Sequel::Model)
        ).returns(T.untyped)
      end
      def self.execute_policy(policy, subject, actor, direct_object)
        # Arity ≥ 1 policies expect an actor as the first arg; an
        # anonymous viewer auto-denies unless the policy opts in with
        # `allow_anonymous: true` (for subject-only state gates).
        return :deny if !actor && policy.arity >= 1 && !policy.allow_anonymous?

        case policy.arity
        when 0
          Actions.evaluate(&policy)
        when 1
          Actions.evaluate(actor, &policy)
        when 2
          Actions.evaluate(actor, subject, &policy)
        else
          Actions.evaluate(actor, subject, direct_object, &policy)
        end
      end

      sig do
        params(
          policy: Policy,
          result: Symbol,
          actor: T.nilable(IActor),
          subject: TPolicySubject,
          from_cache: T::Boolean,
          skipped: T::Boolean
        ).void
      end
      def self.log_result(policy, result, actor, subject, from_cache, skipped)
        return unless logger

        actor_id = actor ? actor.id : 'anonymous'
        logger.debug do
          msg = "#{result.to_s.upcase}: #{policy.policy_name || 'anonymous'} for actor[#{actor_id}] on #{subject.class}[#{subject_id(subject)}]"
          msg += ' (cached)' if from_cache
          msg += ' (skipped: single_match)' if skipped
          msg
        end

        return unless policy.comment && %i[deny allow].include?(result)

        logger.debug { " ⮑  #{policy.comment}" }
      end

      sig { params(subject: TPolicySubject).returns(T.untyped) }
      def self.subject_id(subject)
        subject.respond_to?(:pk) ? subject.pk : subject.object_id
      end
    end
  end
end
