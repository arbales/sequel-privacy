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

      sig { params(model: T.class_of(Sequel::Model), _opts: T::Hash[Symbol, T.untyped]).void }
      def self.apply(model, _opts = {})
        model.instance_variable_set(:@privacy_policies, {})
        model.instance_variable_set(:@privacy_fields, {})
        model.instance_variable_set(:@privacy_association_policies, {})
        model.instance_variable_set(:@privacy_finalized, false)
        model.instance_variable_set(:@allow_unsafe_access, false)
        model.instance_variable_set(:@privacy_wrapped_association_reflections, {})
      end

      sig { params(model: T.class_of(Sequel::Model), opts: T::Hash[Symbol, T.untyped]).void }
      def self.configure(model, opts = {})
        model.all_association_reflections.each do |reflection|
          model.send(:_setup_privacy_association_readers, reflection[:type], reflection[:name], true)
        end
      end

      class AssociationPrivacyDSL
        extend T::Sig

        sig {
          params(model_class: ClassMethods, assoc_name: Symbol,
                 policy_resolver: T.proc.params(policies: T::Array[T.untyped]).returns(T::Array[T.untyped])).void
        }
        def initialize(model_class, assoc_name, policy_resolver)
          @model_class = model_class
          @assoc_name = assoc_name
          @policy_resolver = policy_resolver
          @pending_policies = T.let({}, T::Hash[Symbol, T::Array[T.untyped]])
        end

        sig { params(action: Symbol, policies: T.untyped).void }
        def can(action, *policies)
          unless %i[add remove remove_all].include?(action)
            Kernel.raise ArgumentError,
                         "Association action must be :add, :remove, or :remove_all, got #{action.inspect}"
          end

          resolved = @policy_resolver.(policies)
          @pending_policies[action] ||= []
          T.must(@pending_policies[action]).concat(resolved)
        end

        sig { void }
        def finalize_association!
          @pending_policies.each do |action, policies|
            @model_class.register_association_policies(@assoc_name, action, policies)
          end
          @model_class.setup_association_privacy(@assoc_name)
        end
      end

      class PrivacyDSL
        extend T::Sig

        sig { params(model_class: ClassMethods).void }
        def initialize(model_class)
          @model_class = model_class
        end

        sig { params(action: Symbol, policies: T.untyped).void }
        def can(action, *policies)
          resolved = resolve_policies(policies)
          @model_class.register_policies(action, resolved)
        end

        sig { params(name: Symbol, policies: T.untyped).void }
        def field(name, *policies)
          resolved = resolve_policies(policies)
          policy_name = :"view_#{name}"
          @model_class.register_policies(policy_name, resolved)
          @model_class.register_protected_field(name, policy_name)
        end

        sig { params(name: Symbol, block: T.proc.bind(AssociationPrivacyDSL).void).void }
        def association(name, &block)
          resolver = ->(policies) { resolve_policies(policies) }
          dsl = AssociationPrivacyDSL.new(@model_class, name, resolver)
          dsl.instance_eval(&block)
          dsl.finalize_association!
        end

        sig { void }
        def finalize!
          @model_class.finalize_privacy!
        end

        private

        sig { params(policies: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
        def resolve_policies(policies)
          policies.map do |p|
            case p
            when Sequel::Privacy::Policy, Proc
              p
            when Sequel::Privacy::PolicyFactory
              Kernel.raise ArgumentError, "Policy factory #{p.factory_name} must be called with arguments"
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

        Sequel::Plugins.inherited_instance_variables(
          self,
          :@privacy_policies => :dup,
          :@privacy_fields => :dup,
          :@privacy_association_policies => :dup,
          :@privacy_wrapped_association_reflections => :dup,
          :@privacy_finalized => nil,
          :@allow_unsafe_access => nil
        )

        # Allows the model to be accessed without a ViewerContext, useful when
        # you're migrating an existing codebase or adopting gradually.
        # You can prevent this from applying to certain fields or associations by
        # passing `except:`.
        sig { params(except: T::Array[Symbol]).void }
        def allow_unsafe_access!(except: [])
          @allow_unsafe_access = T.let(true, T.nilable(T::Boolean))
          @unsafe_access_except = T.let(except.map(&:to_sym), T.nilable(T::Array[Symbol]))
          Sequel::Privacy.logger&.warn("#{self} allows unsafe access - migrate to use for_vc()")
        end

        # Checks if the model or a field/association allows unsafe access.
        sig { params(name: T.nilable(Symbol)).returns(T::Boolean) }
        def allow_unsafe_access?(name = nil)
          return false unless @allow_unsafe_access == true
          return true if name.nil?

          !(@unsafe_access_except || []).include?(name)
        end

        # Per-class thread-local key carrying the current VC during row
        # materialization.
        sig { returns(Symbol) }
        def privacy_vc_key
          :"#{self}_privacy_vc"
        end

        # The primary integration point; every Sequel::Model materialization
        # flows through here.
        sig { params(values: T.untyped).returns(T.nilable(Sequel::Model)) }
        def call(values)
          vc = Thread.current[privacy_vc_key]

          unless vc || allow_unsafe_access?
            Kernel.raise Sequel::Privacy::MissingViewerContext,
                         "#{self} requires a ViewerContext. Use #{self}.for_vc(vc) or call #{self}.allow_unsafe_access!"
          end

          super
        end

        sig { returns(T::Hash[Symbol, T::Array[T.untyped]]) }
        def privacy_policies
          @privacy_policies ||= T.let({}, T.nilable(T::Hash[Symbol, T::Array[T.untyped]]))
        end

        sig { returns(T::Hash[Symbol, Symbol]) }
        def privacy_fields
          @privacy_fields ||= T.let({}, T.nilable(T::Hash[Symbol, Symbol]))
        end

        sig { returns(T::Hash[Symbol, T::Hash[Symbol, T::Array[T.untyped]]]) }
        def privacy_association_policies
          @privacy_association_policies ||= T.let({}, T.nilable(T::Hash[Symbol, T::Hash[Symbol, T::Array[T.untyped]]]))
        end

        sig { returns(T::Boolean) }
        def privacy_finalized?
          @privacy_finalized == true
        end

        # Entry point for the privacy DSL. The block is evaluated in the
        # context of a `PrivacyDSL` instance:
        #
        #   privacy do
        #     can :view, P::AllowMembers
        #     can :edit, P::AllowSelf, P::AllowAdmins
        #     field :email, P::AllowSelf
        #   end
        sig { params(block: T.proc.bind(PrivacyDSL).void).void }
        def privacy(&block)
          if privacy_finalized?
            Kernel.raise Sequel::Privacy::PrivacyAlreadyFinalizedError, "Privacy already finalized for #{self}"
          end

          dsl = PrivacyDSL.new(self)
          dsl.instance_eval(&block)
        end

        sig { params(action: Symbol, policies: T::Array[T.untyped]).void }
        def register_policies(action, policies)
          if privacy_finalized?
            Kernel.raise Sequel::Privacy::PrivacyAlreadyFinalizedError, "Privacy already finalized for #{self}"
          end

          privacy_policies[action] ||= []
          T.must(privacy_policies[action]).concat(policies)
        end

        sig { params(field: Symbol, policy_name: Symbol).void }
        def register_protected_field(field, policy_name)
          if privacy_finalized?
            Kernel.raise Sequel::Privacy::PrivacyAlreadyFinalizedError, "Privacy already finalized for #{self}"
          end

          privacy_fields[field] = policy_name

          original_method = instance_method(field)

          define_method(field) do
            return original_method.bind(self).() if Sequel::Privacy::Enforcer.in_policy_eval?

            vc = instance_variable_get(:@viewer_context)

            unless vc
              return original_method.bind(self).() if T.unsafe(self.class).allow_unsafe_access?(field)

              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "#{self.class}##{field} requires a ViewerContext"
            end

            value = original_method.bind(self).()
            return unless T.cast(self, InstanceMethods).allow?(vc, policy_name)

            value
          end
        end

        # The caller is responsible for invoking `setup_association_privacy`
        # once all actions have been registered.
        sig { params(assoc_name: Symbol, action: Symbol, policies: T::Array[T.untyped]).void }
        def register_association_policies(assoc_name, action, policies)
          Kernel.raise "Privacy policies have been finalized for #{self}" if privacy_finalized?

          privacy_association_policies[assoc_name] ||= {}
          assoc_hash = T.must(privacy_association_policies[assoc_name])
          assoc_hash[action] ||= []
          T.must(assoc_hash[action]).concat(policies)
        end

        # Wraps add_*/remove_*/remove_all_* methods on an association
        # with privacy checks. Idempotent.
        sig { params(assoc_name: Symbol).void }
        def setup_association_privacy(assoc_name)
          assoc_policies = privacy_association_policies[assoc_name]
          return unless assoc_policies

          reflection = association_reflection(assoc_name)
          return unless reflection

          @_wrapped_associations ||= T.let({}, T.nilable(T::Hash[Symbol, T::Boolean]))
          return if @_wrapped_associations[assoc_name]

          @_wrapped_associations[assoc_name] = true

          # Sequel derives mutator names by stripping a trailing 's' from
          # the association name: many_to_many :members → add_member,
          # one_to_many :memberships → add_membership.
          #
          # TODO: I'm not sure if this will break sometimes.
          singular_name = reflection[:name].to_s.chomp('s').to_sym

          add_policies = assoc_policies[:add]
          if add_policies && method_defined?(:"add_#{singular_name}")
            _wrap_association_add(assoc_name, singular_name, add_policies)
          end

          remove_policies = assoc_policies[:remove]
          if remove_policies && method_defined?(:"remove_#{singular_name}")
            _wrap_association_remove(assoc_name, singular_name, remove_policies)
          end

          remove_all_policies = assoc_policies[:remove_all]
          return unless remove_all_policies && method_defined?(:"remove_all_#{reflection[:name]}")

          _wrap_association_remove_all(assoc_name, reflection[:name], remove_all_policies)
        end

        # TODO: explore automatic finalization on first query.
        sig { void }
        def finalize_privacy!
          @privacy_finalized = T.let(true, T.nilable(T::Boolean))
        end

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
          register_protected_field(field, policy_name)
        end

        # Create a privacy-aware dataset
        sig { params(vc: Sequel::Privacy::ViewerContext).returns(Sequel::Dataset) }
        def for_vc(vc)
          dataset.for_vc(vc)
        end

        sig { params(type: Symbol, name: Symbol, opts: T.untyped, block: T.untyped).returns(T.untyped) }
        def associate(type, name, opts = {}, &block)
          opts = _inject_privacy_eager_block(opts)
          result = super

          _setup_privacy_association_readers(type, name, false)

          result
        end

        # Inject an :eager_block that wraps the eager-load dataset with
        # `for_vc` when a VC is propagated via EAGER_VC_KEY (see
        # DatasetMethods#post_load). Preserves any user-supplied block.
        sig { params(opts: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
        def _inject_privacy_eager_block(opts)
          opts.merge(eager_block: _privacy_eager_block(opts[:eager_block]))
        end

        sig { params(original: T.untyped).returns(Proc) }
        def _privacy_eager_block(original)
          wrapped = proc do |ds|
            ds = original.call(ds) if original
            vc = Thread.current[DatasetMethods::EAGER_VC_KEY]
            if vc && T.unsafe(ds).model.respond_to?(:privacy_vc_key)
              T.unsafe(ds).for_vc(vc)
            else
              ds
            end
          end
          wrapped
        end

        private

        sig { params(type: Symbol, name: Symbol, inject_eager_block: T::Boolean).void }
        def _setup_privacy_association_readers(type, name, inject_eager_block)
          reflection = association_reflection(name)
          return unless reflection

          @privacy_wrapped_association_reflections ||= T.let(
            {},
            T.nilable(T::Hash[Symbol, T.untyped])
          )
          wrapped = @privacy_wrapped_association_reflections
          return if wrapped[name].equal?(reflection)

          if inject_eager_block
            reflection[:eager_block] = _privacy_eager_block(reflection[:eager_block])
          end

          case type
          when :many_to_one, :one_to_one
            _override_singular_association(name)
            _override_association_dataset(name)
          when :one_to_many, :many_to_many
            _override_plural_association(name)
            _override_association_dataset(name)
            setup_association_privacy(name) if privacy_association_policies[name]
          end

          wrapped[name] = reflection
        end

        sig { params(name: Symbol).void }
        def _override_association_dataset(name)
          dataset_method = :"#{name}_dataset"
          return unless method_defined?(dataset_method)

          original = instance_method(dataset_method)
          assoc_reflection = association_reflection(name)
          assoc_class = T.let(nil, T.nilable(T.class_of(Sequel::Model)))

          define_method(dataset_method) do |*args|
            ds = original.bind(self).(*args)
            vc = instance_variable_get(:@viewer_context)
            return ds unless vc

            assoc_class ||= assoc_reflection.associated_class
            if assoc_class.respond_to?(:privacy_vc_key) && ds.respond_to?(:for_vc)
              T.unsafe(ds).for_vc(vc)
            else
              ds
            end
          end
        end

        sig { params(name: Symbol).void }
        def _override_singular_association(name)
          original = instance_method(name)
          assoc_reflection = association_reflection(name)
          # Resolve lazily to handle forward references between models.
          assoc_class = T.let(nil, T.nilable(T.class_of(Sequel::Model)))

          define_method(name) do
            vc = instance_variable_get(:@viewer_context)

            if vc.nil? && !T.unsafe(self.class).allow_unsafe_access?(name)
              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "#{self.class}##{name} requires a ViewerContext"
            end

            assoc_class ||= assoc_reflection.associated_class

            obj = if vc && assoc_class.respond_to?(:privacy_vc_key)
                    vc_key = assoc_class.privacy_vc_key
                    old_vc = Thread.current[vc_key]
                    Thread.current[vc_key] = vc
                    begin
                      original.bind(self).()
                    ensure
                      Thread.current[vc_key] = old_vc
                    end
                  else
                    original.bind(self).()
                  end

            return nil unless obj
            return obj unless vc
            return obj if Sequel::Privacy::Enforcer.in_policy_eval?

            privacy_aware = obj.is_a?(Sequel::Model) && obj.class.respond_to?(:privacy_vc_key)
            obj.instance_variable_set(:@viewer_context, vc) if privacy_aware

            if privacy_aware && !T.cast(obj, InstanceMethods).allow?(vc, :view)
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

            if vc.nil? && !T.unsafe(self.class).allow_unsafe_access?(name)
              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "#{self.class}##{name} requires a ViewerContext"
            end

            assoc_class ||= assoc_reflection.associated_class

            objs = if vc && assoc_class.respond_to?(:privacy_vc_key)
                     vc_key = assoc_class.privacy_vc_key
                     old_vc = Thread.current[vc_key]
                     Thread.current[vc_key] = vc
                     begin
                       original.bind(self).()
                     ensure
                       Thread.current[vc_key] = old_vc
                     end
                   else
                     original.bind(self).()
                   end

            return objs unless vc
            return objs if Sequel::Privacy::Enforcer.in_policy_eval?

            objs.filter_map do |obj|
              privacy_aware = obj.is_a?(Sequel::Model) && obj.class.respond_to?(:privacy_vc_key)
              obj.instance_variable_set(:@viewer_context, vc) if privacy_aware

              if privacy_aware && !T.cast(obj, InstanceMethods).allow?(vc, :view)
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
              return original.bind(self).(obj) if T.unsafe(self.class).allow_unsafe_access?(assoc_name)

              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "Cannot #{method_name} without a viewer context"
            end

            if vc.is_a?(Sequel::Privacy::OmniscientVC)
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} with OmniscientVC"
            end

            allowed = Sequel::Privacy::Enforcer.enforce(policies, self, vc, obj)

            unless allowed
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} on #{self.class}"
            end

            original.bind(self).(obj)
          end
        end

        sig { params(assoc_name: Symbol, singular_name: Symbol, policies: T::Array[T.untyped]).void }
        def _wrap_association_remove(assoc_name, singular_name, policies)
          method_name = :"remove_#{singular_name}"
          original = instance_method(method_name)

          define_method(method_name) do |obj|
            vc = instance_variable_get(:@viewer_context)

            unless vc
              return original.bind(self).(obj) if T.unsafe(self.class).allow_unsafe_access?(assoc_name)

              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "Cannot #{method_name} without a viewer context"
            end

            if vc.is_a?(Sequel::Privacy::OmniscientVC)
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} with OmniscientVC"
            end

            allowed = Sequel::Privacy::Enforcer.enforce(policies, self, vc, obj)

            unless allowed
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} on #{self.class}"
            end

            original.bind(self).(obj)
          end
        end

        sig { params(assoc_name: Symbol, plural_name: Symbol, policies: T::Array[T.untyped]).void }
        def _wrap_association_remove_all(assoc_name, plural_name, policies)
          method_name = :"remove_all_#{plural_name}"
          original = instance_method(method_name)

          define_method(method_name) do
            vc = instance_variable_get(:@viewer_context)

            unless vc
              return original.bind(self).() if T.unsafe(self.class).allow_unsafe_access?(assoc_name)

              Kernel.raise Sequel::Privacy::MissingViewerContext,
                           "Cannot #{method_name} without a viewer context"
            end

            if vc.is_a?(Sequel::Privacy::OmniscientVC)
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} with OmniscientVC"
            end

            allowed = Sequel::Privacy::Enforcer.enforce(policies, self, vc)

            unless allowed
              Kernel.raise Sequel::Privacy::Unauthorized,
                           "Cannot #{method_name} on #{self.class}"
            end

            original.bind(self).()
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

        sig { params(vc: Sequel::Privacy::ViewerContext).returns(T.self_type) }
        def for_vc(vc)
          @viewer_context = T.let(vc, T.nilable(Sequel::Privacy::ViewerContext))
          self
        end

        sig do
          params(
            vc: Sequel::Privacy::ViewerContext,
            action: Symbol,
            direct_object: T.nilable(Sequel::Model)
          ).returns(T::Boolean)
        end
        def allow?(vc, action, direct_object = nil)
          policies = _privacy_class.privacy_policies[action]
          unless policies
            Sequel::Privacy.logger&.error("No policies defined for :#{action} on #{self.class}")
            return false
          end

          Sequel::Privacy::Enforcer.enforce(policies, self, vc, direct_object)
        end

        sig { params(opts: T.untyped).returns(T.nilable(T.self_type)) }
        def save(*opts)
          vc = viewer_context

          if vc.is_a?(Sequel::Privacy::OmniscientVC)
            Kernel.raise Sequel::Privacy::Unauthorized, 'Cannot mutate with OmniscientVC'
          end

          if vc
            action = new? ? :create : :edit

            Kernel.raise Sequel::Privacy::Unauthorized, "Cannot #{action} #{self.class}" unless allow?(vc, action)

            changed_columns.each do |field|
              policy = _privacy_class.privacy_fields[field]
              next unless policy

              unless allow?(vc, policy)
                Kernel.raise Sequel::Privacy::FieldUnauthorized,
                             "Cannot modify #{self.class}##{field} (policy: #{policy})"
              end
            end
          end

          super
        end

        sig { params(hash: T::Hash[Symbol, T.untyped]).returns(T.self_type) }
        def update(hash)
          vc = viewer_context
          if vc
            Kernel.raise Sequel::Privacy::Unauthorized, "Cannot edit #{self.class}" unless allow?(vc, :edit)

            hash.each_key do |field|
              policy = _privacy_class.privacy_fields[field]
              next unless policy

              unless allow?(vc, policy)
                Kernel.raise Sequel::Privacy::FieldUnauthorized,
                             "Cannot modify #{self.class}##{field} (policy: #{policy})"
              end
            end
          end

          super
        end

        private

        # Every class that includes InstanceMethods also extends ClassMethods
        # via `mixes_in_class_methods`, so this should always work.
        sig { returns(ClassMethods) }
        def _privacy_class
          T.cast(self.class, ClassMethods)
        end

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

        # Thread-local key for propagating the current VC to eager-load
        # datasets via the :eager_block injected in ClassMethods#associate.
        EAGER_VC_KEY = :sequel_privacy_eager_vc

        sig { params(vc: Sequel::Privacy::ViewerContext).returns(Sequel::Dataset) }
        def for_vc(vc)
          clone(viewer_context: vc)
        end

        # Stores the ViewerContext in a Thread-local that Model.call
        # can retreive. Materializes the model, and then checks the view
        # policy. If the model is being materialized within the context of
        # checking a policy this is bypassed, because policies often need to
        # check data that a VC might not have permission to see. The check is also
        # bypassed for eager loads, and checked on the association.
        sig { returns(T.untyped) }
        def row_proc
          vc = opts[:viewer_context]
          return super unless vc

          model_class = T.cast(model, ClassMethods)
          vc_key = model_class.privacy_vc_key
          proc do |values|
            old_vc = Thread.current[vc_key]
            Thread.current[vc_key] = vc
            begin
              instance = model_class.(values)
            ensure
              Thread.current[vc_key] = old_vc
            end

            next nil if instance.nil?

            instance.instance_variable_set(:@viewer_context, vc)
            next instance if Sequel::Privacy::Enforcer.in_policy_eval?
            next instance if Thread.current[EAGER_VC_KEY]

            if T.cast(instance, InstanceMethods).allow?(vc, :view)
              instance
            else
              Sequel::Privacy.logger&.debug { "Privacy denied :view on #{model_class}[#{instance.pk}]" }
              nil
            end
          end
        end

        sig { returns(T::Array[T.attached_class]) }
        def all
          results = super
          opts[:viewer_context] ? results.compact : results
        end

        # Sequel's Model#post_load triggers eager_load. We expose the VC
        # via EAGER_VC_KEY around that call so the :eager_block injected
        # in ClassMethods#associate can wrap each child dataset with
        # for_vc. Parents already filtered to nil by row_proc must be
        # compacted first — eager_load's attachment code can't handle
        # nil records.
        sig { params(all_records: T.untyped).returns(T.untyped) }
        def post_load(all_records)
          vc = opts[:viewer_context]
          return super unless vc && opts[:eager]

          all_records.compact!

          old = Thread.current[EAGER_VC_KEY]
          Thread.current[EAGER_VC_KEY] = vc
          begin
            super
          ensure
            Thread.current[EAGER_VC_KEY] = old
          end
        end

        sig { params(values: T::Hash[Symbol, T.untyped]).returns(T.attached_class) }
        def new(values = {})
          instance = T.unsafe(model).new(values)
          if (vc = opts[:viewer_context])
            instance.instance_variable_set(:@viewer_context, vc)
          end
          instance
        end

        sig { params(values: T::Hash[Symbol, T.untyped]).returns(T.attached_class) }
        def create(values = {})
          T.cast(new(values), Sequel::Model).save
        end
      end
    end
  end
end
