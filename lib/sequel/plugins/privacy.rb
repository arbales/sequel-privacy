# typed: strict
# frozen_string_literal: true

require 'sequel-privacy'

module Sequel
  module Plugins
    # Privacy plugin for Sequel models.
    #
    # Provides:
    # - Policy definition DSL (`policies` method)
    # - Field-level privacy protection (`protect_field` method)
    # - Privacy-aware queries (`for_vc` method)
    # - Automatic association privacy enforcement
    #
    # Usage:
    #   class Member < Sequel::Model
    #     plugin :privacy
    #
    #     policies :view, P::AllowSelf, P::AllowAdmins, P::AlwaysDeny
    #     policies :view_email, P::AllowMembers, P::AlwaysDeny
    #     policies :edit, P::AllowSelf, P::AllowAdmins, P::AlwaysDeny
    #
    #     protect_field :email
    #     protect_field :phone, policy: :view_phone
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
        model.instance_variable_set(:@allow_unsafe_access, false)
      end

      # Called every time plugin loads (for per-model configuration)
      sig { params(model: T.class_of(Sequel::Model), opts: T::Hash[Symbol, T.untyped]).void }
      def self.configure(model, opts = {})
        # Currently no per-model configuration needed
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
            unless vc.is_a?(Sequel::Privacy::InternalPolicyEvaluationVC)
              unless instance.allow?(vc, :view)
                Sequel::Privacy.logger&.debug { "Privacy denied :view on #{self}[#{instance.pk}]" }
                return nil # Filtered out
              end
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

        # Define policies for an action.
        #
        # @param action [Symbol] The action name (:view, :edit, :create, :view_email, etc.)
        # @param policy_chain [Array<Policy>] The policies to evaluate in order
        sig { params(action: Symbol, policy_chain: T.untyped).void }
        def policies(action, *policy_chain)
          if privacy_policies.key?(action)
            Kernel.raise "Cannot redefine policies for :#{action} on #{self}"
          end
          privacy_policies[action] = policy_chain
        end

        # ─────────────────────────────────────────────────────────────────────
        # Field-Level Privacy
        # ─────────────────────────────────────────────────────────────────────

        sig { returns(T::Hash[Symbol, Symbol]) }
        def privacy_fields
          @privacy_fields ||= T.let({}, T.nilable(T::Hash[Symbol, Symbol]))
        end

        # Mark a field as privacy-protected.
        # Access will return nil if the viewer doesn't have permission.
        #
        # @param field [Symbol] The field name to protect
        # @param policy [Symbol, nil] The policy to check (defaults to :view_#{field})
        sig { params(field: Symbol, policy: T.nilable(Symbol)).void }
        def protect_field(field, policy: nil)
          policy_name = policy || :"view_#{field}"
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
      end

      module InstanceMethods
        extend T::Sig
        extend T::Helpers

        requires_ancestor { Sequel::Model }
        mixes_in_class_methods(ClassMethods)


        sig { returns(T.nilable(Sequel::Privacy::ViewerContext)) }
        def viewer_context
          @viewer_context
        end

        sig { params(vc: T.nilable(Sequel::Privacy::ViewerContext)).returns(T.nilable(Sequel::Privacy::ViewerContext)) }
        def viewer_context=(vc)
          @viewer_context = vc
        end

        # Attach a viewer context to this model instance
        sig { params(vc: Sequel::Privacy::ViewerContext).returns(T.self_type) }
        def for_vc(vc)
          @viewer_context = vc
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
          saved_vc = @viewer_context
          @viewer_context = Sequel::Privacy::InternalPolicyEvaluationVC.new
          begin
            Sequel::Privacy::Enforcer.enforce(policies, self, vc, direct_object)
          ensure
            @viewer_context = saved_vc
          end
        end

        # Override save to check privacy policies
        sig { params(opts: T.untyped).returns(T.nilable(T.self_type)) }
        def save(*opts)
          vc = @viewer_context
          if vc
            action = new? ? :create : :edit

            unless allow?(vc, action)
              Kernel.raise Sequel::Privacy::Unauthorized, "Cannot #{action} #{self.class}"
            end

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
          vc = @viewer_context
          if vc
            unless allow?(vc, :edit)
              Kernel.raise Sequel::Privacy::Unauthorized, "Cannot edit #{self.class}"
            end

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

        # Override each to set thread-local VC during row processing.
        # This allows Model.call to see the VC and enforce privacy.
        sig { params(block: T.proc.params(arg0: T.attached_class).void).void }
        def each(&block)
          vc = opts[:viewer_context]

          if vc
            model_class = T.unsafe(model)
            vc_key = model_class.privacy_vc_key
            old_vc = Thread.current[vc_key]
            Thread.current[vc_key] = vc
            begin
              super { |row| yield(row) if row }
            ensure
              Thread.current[vc_key] = old_vc
            end
          else
            super
          end
        end

        # Override all to filter out nil results from privacy checks
        sig { returns(T::Array[T.attached_class]) }
        def all
          results = super
          if opts[:viewer_context]
            results.compact
          else
            results
          end
        end

        # Override first to handle nil from privacy check
        sig { params(args: T.untyped).returns(T.nilable(T.attached_class)) }
        def first(*args)
          vc = opts[:viewer_context]

          if vc
            model_class = T.unsafe(model)
            vc_key = model_class.privacy_vc_key
            old_vc = Thread.current[vc_key]
            Thread.current[vc_key] = vc
            begin
              super
            ensure
              Thread.current[vc_key] = old_vc
            end
          else
            super
          end
        end
      end
    end
  end
end
