# typed: strict
# frozen_string_literal: true

require 'sequel-privacy'

module Sequel
  module Plugins
    # Privacy plugin for Sequel models.
    #
    # Provides:
    # - Policy definition DSL (`privacy` block)
    # - Field-level privacy protection (`field` in privacy block)
    # - Privacy-aware queries (`for_vc` method)
    # - Automatic association privacy enforcement
    #
    # Usage:
    #   class Member < Sequel::Model
    #     plugin :privacy
    #
    #     privacy do
    #       can :view, P::AllowSelf, P::AllowAdmins
    #       can :edit, P::AllowSelf, P::AllowAdmins
    #
    #       field :email, P::AllowSelf
    #       field :phone, P::AllowSelf, P::AllowFriends
    #     end
    #   end
    #
    #   # Query with privacy enforcement
    #   vc = Sequel::Privacy::ViewerContext.for_actor(current_user)
    #   members = Member.for_vc(vc).where(org_id: 1).all
    #
    #   # Check permissions
    #   member.allow?(vc, :view)  # => true/false
    #   member.email              # => nil if :view_email denies
    module Privacy
      extend T::Sig

      # Called once when plugin first loads on a model
      sig { params(model: T.class_of(Sequel::Model), opts: T::Hash[Symbol, T.untyped]).void }
      def self.apply(model, opts = {})
        model.instance_variable_set(:@privacy_policies, {})
        model.instance_variable_set(:@privacy_fields, {})
        model.instance_variable_set(:@privacy_association_policies, {})
        model.instance_variable_set(:@privacy_finalized, false)
        model.instance_variable_set(:@allow_unsafe_access, false)
      end

      # Called every time plugin loads (for per-model configuration)
      sig { params(model: T.class_of(Sequel::Model), opts: T::Hash[Symbol, T.untyped]).void }
      def self.configure(model, opts = {})
        # Currently no per-model configuration needed
      end

      # DSL class for defining association-level privacy policies
      class AssociationPrivacyDSL
        extend T::Sig

        sig {
          params(model_class: T.untyped, assoc_name: Symbol,
                 policy_resolver: T.proc.params(policies: T::Array[T.untyped]).returns(T::Array[T.untyped])).void
        }
        def initialize(model_class, assoc_name, policy_resolver)
          @model_class = model_class
          @assoc_name = assoc_name
          @policy_resolver = policy_resolver
          @pending_policies = T.let({}, T::Hash[Symbol, T::Array[T.untyped]])
        end

        # Define policies for association actions (:add, :remove, :remove_all)
        sig { params(action: Symbol, policies: T.untyped).void }
        def can(action, *policies)
          unless %i[add remove remove_all].include?(action)
            Kernel.raise ArgumentError,
                         "Association action must be :add, :remove, or :remove_all, got #{action.inspect}"
          end

          resolved = @policy_resolver.call(policies)
          @pending_policies[action] ||= []
          T.must(@pending_policies[action]).concat(resolved)
        end

        # Called after the association block is evaluated to register all policies at once
        sig { void }
        def finalize_association!
          @pending_policies.each do |action, policies|
            T.unsafe(@model_class).register_association_policies(@assoc_name, action, policies, defer_setup: true)
          end
          # Now set up the privacy wrappers after all policies are registered
          T.unsafe(@model_class).setup_association_privacy(@assoc_name)
        end
      end

      # DSL class for defining privacy policies in a block
      class PrivacyDSL
        extend T::Sig

        sig { params(model_class: T.untyped).void }
        def initialize(model_class)
          @model_class = model_class
        end

        # Define policies for an action
        sig { params(action: Symbol, policies: T.untyped).void }
        def can(action, *policies)
          resolved = resolve_policies(policies)
          T.unsafe(@model_class).register_policies(action, resolved)
        end

        # Define a protected field with its policies
        sig { params(name: Symbol, policies: T.untyped).void }
        def field(name, *policies)
          resolved = resolve_policies(policies)
          policy_name = :"view_#{name}"
          T.unsafe(@model_class).register_policies(policy_name, resolved)
          T.unsafe(@model_class).register_protected_field(name, policy_name)
        end

        # Define policies for an association
        #
        # Example:
        #   association :members do
        #     can :add, AllowGroupAdmin, AllowSelfJoin
        #     can :remove, AllowGroupAdmin, AllowSelfRemove
        #     can :remove_all, AllowGroupAdmin
        #   end
        sig { params(name: Symbol, block: T.proc.void).void }
        def association(name, &block)
          resolver = ->(policies) { resolve_policies(policies) }
          dsl = AssociationPrivacyDSL.new(@model_class, name, resolver)
          dsl.instance_eval(&block)
          dsl.finalize_association!
        end

        # Finalize privacy settings (no more changes allowed)
        sig { void }
        def finalize!
          T.unsafe(@model_class).finalize_privacy!
        end

        private

        sig { params(policies: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
        def resolve_policies(policies)
          policies.map do |p|
            case p
            when Sequel::Privacy::Policy, Proc
              p
            else
              Kernel.raise ArgumentError, "Invalid policy: #{p.inspect}"
            end
          end
        end
      end

      module ClassMethods
        extend T::Sig
        extend T::Helpers

        requires_ancestor { T.class_of(Sequel::Model) }

        # Register inherited instance variables for proper subclass handling
        Sequel::Plugins.inherited_instance_variables(
          self,
          :@privacy_policies => :dup,
          :@privacy_fields => :dup,
          :@privacy_association_policies => :dup,
          :@privacy_finalized => nil,
          :@allow_unsafe_access => nil
        )

        # ─────────────────────────────────────────────────────────────────────
        # Strict Mode Enforcement
        # ─────────────────────────────────────────────────────────────────────

        # Allow this model to be accessed without a ViewerContext.
        # Use during migration to gradually enable strict mode.
        sig { void }
        def allow_unsafe_access!
          @allow_unsafe_access = T.let(true, T.nilable(T::Boolean))
          Sequel::Privacy.logger&.warn("#{self} allows unsafe access - migrate to use for_vc()")
        end

        sig { returns(T::Boolean) }
        def allow_unsafe_access?
          @allow_unsafe_access == true
        end

        # Thread-local key for storing the current ViewerContext during row processing
        sig { returns(Symbol) }
        def privacy_vc_key
          :"#{self}_privacy_vc"
        end

        # Override Sequel's call method - this is the lowest-level instantiation point
        # for ALL database-loaded records. Every path goes through here:
        # - Model[id], Model.first, Model.all, associations, etc.
        sig { params(values: T.untyped).returns(T.nilable(Sequel::Model)) }
        def call(values)
          # Check if we're in a VC context (thread-local set by for_vc)
          vc = Thread.current[privacy_vc_key]

          unless vc || allow_unsafe_access?
            Kernel.raise Sequel::Privacy::MissingViewerContext,
                         "#{self} requires a ViewerContext. Use #{self}.for_vc(vc) or call #{self}.allow_unsafe_access!"
          end

          # Create the instance via parent chain
          instance = super

          # Attach VC if present
          if vc && instance
            instance.instance_variable_set(:@viewer_context, vc)

            # Check :view policy (skip for InternalPolicyEvaluationVC - used during policy evaluation)
            if !vc.is_a?(Sequel::Privacy::InternalPolicyEvaluationVC) && !instance.allow?(vc, :view)
              Sequel::Privacy.logger&.debug { "Privacy denied :view on #{self}[#{instance.pk}]" }
              return nil # Filtered out
            end
          end

          instance
        end

        # ─────────────────────────────────────────────────────────────────────
        # Policy Definition DSL
        # ─────────────────────────────────────────────────────────────────────

        sig { returns(T::Hash[Symbol, T::Array[T.untyped]]) }
        def privacy_policies
          @privacy_policies ||= T.let({}, T.nilable(T::Hash[Symbol, T::Array[T.untyped]]))
        end

        sig { returns(T::Hash[Symbol, Symbol]) }
        def privacy_fields
          @privacy_fields ||= T.let({}, T.nilable(T::Hash[Symbol, Symbol]))
        end

        # Returns association policies: { assoc_name => { action => [policies] } }
        sig { returns(T::Hash[Symbol, T::Hash[Symbol, T::Array[T.untyped]]]) }
        def privacy_association_policies
          @privacy_association_policies ||= T.let({}, T.nilable(T::Hash[Symbol, T::Hash[Symbol, T::Array[T.untyped]]]))
        end

        sig { returns(T::Boolean) }
        def privacy_finalized?
          @privacy_finalized == true
        end

        # DSL entry point for defining privacy policies
        #
        # @yield Block evaluated in context of PrivacyDSL
        #
        # Example:
        #   privacy do
        #     can :view, P::AllowMembers
        #     can :edit, P::AllowSelf, P::AllowAdmins
        #     field :email, P::AllowSelf
        #   end
        sig { params(block: T.proc.void).void }
        def privacy(&block)
          if privacy_finalized?
            Kernel.raise Sequel::Privacy::PrivacyAlreadyFinalizedError, "Privacy already finalized for #{self}"
          end

          dsl = PrivacyDSL.new(self)
          dsl.instance_eval(&block)
        end

        # Register policies for an action (called by PrivacyDSL)
        sig { params(action: Symbol, policies: T::Array[T.untyped]).void }
        def register_policies(action, policies)
          if privacy_finalized?
            Kernel.raise Sequel::Privacy::PrivacyAlreadyFinalizedError, "Privacy already finalized for #{self}"
          end

          privacy_policies[action] ||= []
          T.must(privacy_policies[action]).concat(policies)
        end

        # Register a protected field (called by PrivacyDSL)
        sig { params(field: Symbol, policy_name: Symbol).void }
        def register_protected_field(field, policy_name)
          if privacy_finalized?
            Kernel.raise Sequel::Privacy::PrivacyAlreadyFinalizedError, "Privacy already finalized for #{self}"
          end

          privacy_fields[field] = policy_name

          # Store original method
          original_method = instance_method(field)

          # Override the field getter
          define_method(field) do
            vc = instance_variable_get(:@viewer_context)

            # Require VC for protected field access
            unless vc
              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "#{self.class}##{field} requires a ViewerContext"
            end

            value = original_method.bind(self).call

            # InternalPolicyEvaluationVC = return raw value (for policy checks)
            return value if vc.is_a?(Sequel::Privacy::InternalPolicyEvaluationVC)

            # Check privacy policy
            if T.unsafe(self).allow?(vc, policy_name)
              value
            else
              nil
            end
          end
        end

        # Register association policies (called by AssociationPrivacyDSL)
        # @param defer_setup [Boolean] If true, don't set up wrappers yet (caller will call setup_association_privacy)
        sig { params(assoc_name: Symbol, action: Symbol, policies: T::Array[T.untyped], defer_setup: T::Boolean).void }
        def register_association_policies(assoc_name, action, policies, defer_setup: false)
          Kernel.raise "Privacy policies have been finalized for #{self}" if privacy_finalized?

          privacy_association_policies[assoc_name] ||= {}
          assoc_hash = T.must(privacy_association_policies[assoc_name])
          assoc_hash[action] ||= []
          T.must(assoc_hash[action]).concat(policies)

          # Set up the association method overrides if the association exists (unless deferred)
          setup_association_privacy(assoc_name) if !defer_setup && association_reflection(assoc_name)
        end

        # Set up privacy-wrapped add_*/remove_*/remove_all_* methods for an association
        # This is called after all policies for an association have been registered
        sig { params(assoc_name: Symbol).void }
        def setup_association_privacy(assoc_name)
          assoc_policies = privacy_association_policies[assoc_name]
          return unless assoc_policies

          reflection = association_reflection(assoc_name)
          return unless reflection

          # Track which associations have been wrapped to avoid double-wrapping
          @_wrapped_associations ||= T.let({}, T.nilable(T::Hash[Symbol, T::Boolean]))
          return if @_wrapped_associations[assoc_name]

          @_wrapped_associations[assoc_name] = true

          # Determine the singular name for method naming
          # For many_to_many :members, methods are add_member, remove_member
          # For one_to_many :memberships, methods are add_membership, remove_membership
          singular_name = reflection[:name].to_s.chomp('s').to_sym

          # Wrap add_* method if :add policy exists
          add_policies = assoc_policies[:add]
          if add_policies && method_defined?(:"add_#{singular_name}")
            _wrap_association_add(assoc_name, singular_name, add_policies)
          end

          # Wrap remove_* method if :remove policy exists
          remove_policies = assoc_policies[:remove]
          if remove_policies && method_defined?(:"remove_#{singular_name}")
            _wrap_association_remove(assoc_name, singular_name, remove_policies)
          end

          # Wrap remove_all_* method if :remove_all policy exists
          remove_all_policies = assoc_policies[:remove_all]
          return unless remove_all_policies && method_defined?(:"remove_all_#{reflection[:name]}")

          _wrap_association_remove_all(assoc_name, reflection[:name], remove_all_policies)
        end

        # Finalize privacy settings (no more changes allowed)
        # TODO: Explore automatic finalization on first query
        sig { void }
        def finalize_privacy!
          @privacy_finalized = T.let(true, T.nilable(T::Boolean))
        end

        # ─────────────────────────────────────────────────────────────────────
        # Deprecated Methods (for backwards compatibility)
        # ─────────────────────────────────────────────────────────────────────

        # @deprecated Use `privacy do; can :action, ...; end` instead
        sig { params(action: Symbol, policy_chain: T.untyped).void }
        def policies(action, *policy_chain)
          Kernel.warn "DEPRECATED: #{self}.policies is deprecated. Use `privacy do; can :#{action}, ...; end` instead"
          register_policies(action, policy_chain)
        end

        # @deprecated Use `privacy do; field :name, ...; end` instead
        sig { params(field: Symbol, policy: T.nilable(Symbol)).void }
        def protect_field(field, policy: nil)
          Kernel.warn "DEPRECATED: #{self}.protect_field is deprecated. Use `privacy do; field :#{field}, ...; end` instead"
          policy_name = policy || :"view_#{field}"
          # Need to also register the policy if not already defined
          register_protected_field(field, policy_name)
        end

        # Create a privacy-aware dataset
        sig { params(vc: Sequel::Privacy::ViewerContext).returns(Sequel::Dataset) }
        def for_vc(vc)
          dataset.for_vc(vc)
        end

        # ─────────────────────────────────────────────────────────────────────
        # Association Privacy (hooks into association creation)
        # ─────────────────────────────────────────────────────────────────────

        # Override Sequel's associate method to wrap associations with privacy checks
        sig { params(type: Symbol, name: Symbol, opts: T.untyped, block: T.untyped).returns(T.untyped) }
        def associate(type, name, opts = {}, &block)
          # Call original to create the association
          result = super

          # Wrap the association method with privacy checks
          case type
          when :many_to_one, :one_to_one
            _override_singular_association(name)
          when :one_to_many, :many_to_many
            _override_plural_association(name)
            # Check if there are already privacy policies defined for this association
            setup_association_privacy(name) if privacy_association_policies[name]
          end

          result
        end

        private

        sig { params(name: Symbol).void }
        def _override_singular_association(name)
          original = instance_method(name)
          assoc_reflection = association_reflection(name)
          assoc_class = T.let(nil, T.nilable(T.class_of(Sequel::Model)))

          define_method(name) do
            vc = instance_variable_get(:@viewer_context)

            # Determine associated class (lazily, to handle forward references)
            assoc_class ||= assoc_reflection.associated_class

            # Load association with VC context set if available
            obj = if vc && assoc_class.respond_to?(:privacy_vc_key)
                    vc_key = assoc_class.privacy_vc_key
                    old_vc = Thread.current[vc_key]
                    Thread.current[vc_key] = vc
                    begin
                      original.bind(self).call
                    ensure
                      Thread.current[vc_key] = old_vc
                    end
                  else
                    original.bind(self).call
                  end

            return nil unless obj
            return obj unless vc

            # InternalPolicyEvaluationVC = return raw data (for policy checks)
            # This allows policies to access associations without filtering
            return obj if vc.is_a?(Sequel::Privacy::InternalPolicyEvaluationVC)

            # Attach viewer context to associated object
            obj.instance_variable_set(:@viewer_context, vc) if obj.respond_to?(:allow?)

            # Check :view policy on associated object
            if obj.respond_to?(:allow?) && !obj.allow?(vc, :view)
              nil
            else
              obj
            end
          end
        end

        sig { params(name: Symbol).void }
        def _override_plural_association(name)
          original = instance_method(name)
          assoc_reflection = association_reflection(name)
          assoc_class = T.let(nil, T.nilable(T.class_of(Sequel::Model)))

          define_method(name) do
            vc = instance_variable_get(:@viewer_context)

            # Determine associated class (lazily, to handle forward references)
            assoc_class ||= assoc_reflection.associated_class

            # Load association with VC context set if available
            objs = if vc && assoc_class.respond_to?(:privacy_vc_key)
                     vc_key = assoc_class.privacy_vc_key
                     old_vc = Thread.current[vc_key]
                     Thread.current[vc_key] = vc
                     begin
                       original.bind(self).call
                     ensure
                       Thread.current[vc_key] = old_vc
                     end
                   else
                     original.bind(self).call
                   end

            return objs unless vc

            # InternalPolicyEvaluationVC = return raw data (for policy checks like includes_member?)
            # This allows policies to access associations without filtering
            return objs if vc.is_a?(Sequel::Privacy::InternalPolicyEvaluationVC)

            # Filter array, attaching VC and checking :view policy
            objs.filter_map do |obj|
              obj.instance_variable_set(:@viewer_context, vc) if obj.respond_to?(:allow?)

              if obj.respond_to?(:allow?) && !obj.allow?(vc, :view)
                nil
              else
                obj
              end
            end
          end
        end

        sig { params(assoc_name: Symbol, singular_name: Symbol, policies: T::Array[T.untyped]).void }
        def _wrap_association_add(assoc_name, singular_name, policies)
          method_name = :"add_#{singular_name}"
          original = instance_method(method_name)

          define_method(method_name) do |obj|
            vc = instance_variable_get(:@viewer_context)

            unless vc
              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "Cannot #{method_name} without a viewer context"
            end

            if vc.is_a?(Sequel::Privacy::OmniscientVC)
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} with OmniscientVC"
            end

            # Check policy with 3-arity: (subject=self, actor, direct_object=obj)
            allowed = Sequel::Privacy::Enforcer.enforce(policies, self, vc, obj)

            unless allowed
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} on #{self.class}"
            end

            original.bind(self).call(obj)
          end
        end

        sig { params(assoc_name: Symbol, singular_name: Symbol, policies: T::Array[T.untyped]).void }
        def _wrap_association_remove(assoc_name, singular_name, policies)
          method_name = :"remove_#{singular_name}"
          original = instance_method(method_name)

          define_method(method_name) do |obj|
            vc = instance_variable_get(:@viewer_context)

            unless vc
              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "Cannot #{method_name} without a viewer context"
            end

            if vc.is_a?(Sequel::Privacy::OmniscientVC)
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} with OmniscientVC"
            end

            # Check policy with 3-arity: (subject=self, actor, direct_object=obj)
            allowed = Sequel::Privacy::Enforcer.enforce(policies, self, vc, obj)

            unless allowed
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} on #{self.class}"
            end

            original.bind(self).call(obj)
          end
        end

        sig { params(assoc_name: Symbol, plural_name: Symbol, policies: T::Array[T.untyped]).void }
        def _wrap_association_remove_all(assoc_name, plural_name, policies)
          method_name = :"remove_all_#{plural_name}"
          original = instance_method(method_name)

          define_method(method_name) do
            vc = instance_variable_get(:@viewer_context)

            unless vc
              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "Cannot #{method_name} without a viewer context"
            end

            if vc.is_a?(Sequel::Privacy::OmniscientVC)
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} with OmniscientVC"
            end

            # Check policy with 2-arity: (subject=self, actor) - no direct object for remove_all
            allowed = Sequel::Privacy::Enforcer.enforce(policies, self, vc)

            unless allowed
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} on #{self.class}"
            end

            original.bind(self).call
          end
        end
      end

      module InstanceMethods
        extend T::Sig
        extend T::Helpers

        requires_ancestor { Sequel::Model }
        mixes_in_class_methods(ClassMethods)

        sig { returns(T.nilable(Sequel::Privacy::ViewerContext)) }
        def viewer_context
          @viewer_context = T.let(@viewer_context, T.nilable(Sequel::Privacy::ViewerContext))
        end

        sig { params(vc: T.nilable(Sequel::Privacy::ViewerContext)).returns(T.nilable(Sequel::Privacy::ViewerContext)) }
        def viewer_context=(vc)
          @viewer_context = T.let(vc, T.nilable(Sequel::Privacy::ViewerContext))
        end

        # Attach a viewer context to this model instance
        sig { params(vc: Sequel::Privacy::ViewerContext).returns(T.self_type) }
        def for_vc(vc)
          @viewer_context = T.let(vc, T.nilable(Sequel::Privacy::ViewerContext))
          self
        end

        # Check if the viewer is allowed to perform an action.
        #
        # @param vc [ViewerContext] The viewer context
        # @param action [Symbol] The action to check (:view, :edit, :create, etc.)
        # @param direct_object [Sequel::Model, nil] Optional additional context
        # @return [Boolean]
        sig do
          params(
            vc: Sequel::Privacy::ViewerContext,
            action: Symbol,
            direct_object: T.nilable(Sequel::Model)
          ).returns(T::Boolean)
        end
        def allow?(vc, action, direct_object = nil)
          policies = T.unsafe(self.class).privacy_policies[action]
          unless policies
            Sequel::Privacy.logger&.error("No policies defined for :#{action} on #{self.class}")
            return false
          end

          # Use InternalPolicyEvaluationVC during policy evaluation.
          # This signals to association wrappers that they should return raw data
          # without filtering, allowing policies to check things like "is actor a
          # member of this list?" by accessing list.members without recursively
          # checking each member's :view policy.
          saved_vc = viewer_context
          self.viewer_context = Sequel::Privacy::InternalPolicyEvaluationVC.new
          begin
            Sequel::Privacy::Enforcer.enforce(policies, self, vc, direct_object)
          ensure
            self.viewer_context = saved_vc
          end
        end

        # Override save to check privacy policies
        sig { params(opts: T.untyped).returns(T.nilable(T.self_type)) }
        def save(*opts)
          vc = viewer_context

          if vc.is_a?(Sequel::Privacy::OmniscientVC)
            Kernel.raise Sequel::Privacy::Unauthorized, 'Cannot mutate with OmniscientVC'
          end

          if vc
            action = new? ? :create : :edit

            Kernel.raise Sequel::Privacy::Unauthorized, "Cannot #{action} #{self.class}" unless allow?(vc, action)

            # Check field-level policies on changed fields
            changed_columns.each do |field|
              policy = T.unsafe(self.class).privacy_fields[field]
              next unless policy

              unless allow?(vc, policy)
                Kernel.raise Sequel::Privacy::FieldUnauthorized,
                             "Cannot modify #{self.class}##{field} (policy: #{policy})"
              end
            end
          end

          super
        end

        # Override update to check privacy policies
        sig { params(hash: T::Hash[Symbol, T.untyped]).returns(T.self_type) }
        def update(hash)
          vc = viewer_context
          if vc
            Kernel.raise Sequel::Privacy::Unauthorized, "Cannot edit #{self.class}" unless allow?(vc, :edit)

            hash.each_key do |field|
              policy = T.unsafe(self.class).privacy_fields[field]
              next unless policy

              unless allow?(vc, policy)
                Kernel.raise Sequel::Privacy::FieldUnauthorized,
                             "Cannot modify #{self.class}##{field} (policy: #{policy})"
              end
            end
          end

          super
        end

        # Override delete to block OmniscientVC
        sig { returns(T.self_type) }
        def delete
          if viewer_context.is_a?(Sequel::Privacy::OmniscientVC)
            Kernel.raise Sequel::Privacy::Unauthorized, 'Cannot delete with OmniscientVC'
          end
          super
        end
      end

      module DatasetMethods
        extend T::Sig
        extend T::Helpers
        extend T::Generic

        has_attached_class!(:out)
        requires_ancestor { Sequel::Dataset }

        # Attach viewer context to dataset for privacy enforcement on materialization
        sig { params(vc: Sequel::Privacy::ViewerContext).returns(Sequel::Dataset) }
        def for_vc(vc)
          clone(viewer_context: vc)
        end

        # Override row_proc to wrap Model.call with thread-local VC.
        # This is the single integration point that covers all iteration methods.
        sig { returns(T.untyped) }
        def row_proc
          vc = opts[:viewer_context]
          return super unless vc

          model_class = T.unsafe(model)
          vc_key = model_class.privacy_vc_key
          proc do |values|
            old_vc = Thread.current[vc_key]
            Thread.current[vc_key] = vc
            begin
              model_class.call(values)
            ensure
              Thread.current[vc_key] = old_vc
            end
          end
        end

        # Override all to filter out nil results from privacy checks
        sig { returns(T::Array[T.attached_class]) }
        def all
          results = super
          opts[:viewer_context] ? results.compact : results
        end

        # Create a new model instance with the viewer context attached
        sig { params(values: T::Hash[Symbol, T.untyped]).returns(T.attached_class) }
        def new(values = {})
          instance = T.unsafe(model).new(values)
          if (vc = opts[:viewer_context])
            instance.instance_variable_set(:@viewer_context, vc)
          end
          instance
        end

        # Create and save a new model instance with the viewer context attached
        sig { params(values: T::Hash[Symbol, T.untyped]).returns(T.attached_class) }
        def create(values = {})
          T.cast(new(values), Sequel::Model).save
        end
      end
    end
  end
end
