# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sequel::Plugins::Privacy do
  let(:actor) { TestActor.new(1) }
  let(:admin_actor) { TestActor.new(2, roles: [:admin]) }
  let(:vc) { Sequel::Privacy::ViewerContext.for_actor(actor) }
  let(:admin_vc) { Sequel::Privacy::ViewerContext.for_actor(admin_actor) }
  let(:all_powerful_vc) { Sequel::Privacy::ViewerContext.all_powerful(:testing) }

  # Create test table and model for these specs
  before(:all) do
    DB.create_table?(:privacy_test_items) do
      primary_key :id
      String :name
      String :secret_field
      Integer :owner_id
    end

    DB.create_table?(:privacy_test_children) do
      primary_key :id
      String :name
      Integer :parent_id
      Integer :owner_id
    end
  end

  after(:all) do
    DB.drop_table?(:privacy_test_children)
    DB.drop_table?(:privacy_test_items)
  end

  # Define policies for testing
  let(:allow_owner_policy) do
    Sequel::Privacy::Policy.create(:allow_owner, ->(actor, subject) {
      allow if subject.owner_id == actor.id
    })
  end

  let(:allow_admin_policy) do
    Sequel::Privacy::Policy.create(:allow_admin, ->(actor) {
      allow if actor.is_role?(:admin)
    })
  end

  let(:deny_policy) { Sequel::Privacy::BuiltInPolicies::AlwaysDeny }
  let(:allow_policy) { Sequel::Privacy::BuiltInPolicies::AlwaysAllow }

  describe 'ClassMethods' do
    let(:test_class) do
      allow_owner = allow_owner_policy
      allow_admin = allow_admin_policy
      deny = deny_policy

      Class.new(Sequel::Model(:privacy_test_items)) do
        plugin :privacy

        policies :view, allow_owner, allow_admin, deny
        policies :edit, allow_owner, deny
      end
    end

    describe '.policies' do
      it 'defines policies for an action' do
        expect(test_class.privacy_policies[:view]).to be_an(Array)
        expect(test_class.privacy_policies[:view].length).to eq(3)
      end

      it 'allows merging policies for the same action' do
        original_count = test_class.privacy_policies[:view].length
        test_class.class_eval do
          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
        end
        expect(test_class.privacy_policies[:view].length).to eq(original_count + 1)
      end

      it 'raises error when finalized' do
        test_class.finalize_privacy!
        expect {
          test_class.class_eval do
            policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end
        }.to raise_error(/Privacy already finalized/)
      end

      it 'allows different actions to have different policies' do
        expect(test_class.privacy_policies[:view]).not_to eq(test_class.privacy_policies[:edit])
      end
    end

    describe '.privacy_policies' do
      it 'returns a hash of action to policy arrays' do
        expect(test_class.privacy_policies).to be_a(Hash)
        expect(test_class.privacy_policies.keys).to contain_exactly(:view, :edit)
      end
    end

    describe '.protect_field' do
      let(:field_class) do
        allow_owner = allow_owner_policy
        deny = deny_policy

        Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy

          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow, deny
          policies :view_secret_field, allow_owner, deny

          protect_field :secret_field
        end
      end

      it 'registers the field in privacy_fields' do
        expect(field_class.privacy_fields[:secret_field]).to eq(:view_secret_field)
      end

      it 'accepts custom policy name' do
        custom_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
          policies :custom_policy, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          protect_field :name, policy: :custom_policy
        end

        expect(custom_class.privacy_fields[:name]).to eq(:custom_policy)
      end
    end

    describe '.for_vc' do
      let(:simple_class) do
        Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
        end
      end

      it 'returns a dataset with viewer context' do
        ds = simple_class.for_vc(vc)
        expect(ds).to be_a(Sequel::Dataset)
        expect(ds.opts[:viewer_context]).to eq(vc)
      end
    end

    describe '.privacy' do
      let(:allow_owner_p) do
        Sequel::Privacy::Policy.create(:allow_owner, ->(actor, subject) {
          allow if subject.owner_id == actor.id
        })
      end

      let(:allow_admin_p) do
        Sequel::Privacy::Policy.create(:allow_admin, ->(actor) {
          allow if actor.is_role?(:admin)
        })
      end

      it 'defines policies using the new DSL' do
        ao = allow_owner_p
        aa = allow_admin_p
        test_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
        end
        test_class.privacy do
          can :view, ao, aa
          can :edit, ao
        end

        expect(test_class.privacy_policies[:view].length).to eq(2)
        expect(test_class.privacy_policies[:edit].length).to eq(1)
      end

      it 'allows multiple privacy blocks to merge' do
        ao = allow_owner_p
        aa = allow_admin_p
        test_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
        end
        test_class.privacy do
          can :view, ao
        end
        test_class.privacy do
          can :view, aa
        end

        expect(test_class.privacy_policies[:view].length).to eq(2)
      end

      it 'defines protected fields' do
        ao = allow_owner_p
        test_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
        end
        test_class.privacy do
          field :secret_field, ao
        end

        expect(test_class.privacy_fields[:secret_field]).to eq(:view_secret_field)
        expect(test_class.privacy_policies[:view_secret_field].length).to eq(1)
      end

      it 'accepts policies produced by policy factories' do
        policies = Module.new do
          extend Sequel::Privacy::PolicyDSL

          policy_factory :AllowIfConfiguredFieldVisible, ->(field) {
            ->(_actor, subject) { allow if subject.public_send(field) == 'visible' }
          }
        end

        test_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy

          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
            field :name, policies::AllowIfConfiguredFieldVisible(:secret_field)
          end
        end

        visible = test_class.new(name: 'Visible name', secret_field: 'visible', owner_id: 1).for_vc(vc)
        hidden = test_class.new(name: 'Hidden name', secret_field: 'hidden', owner_id: 1).for_vc(vc)

        expect(visible.name).to eq('Visible name')
        expect(hidden.name).to be_nil
      end

      it 'raises a useful error when a policy factory is registered without arguments' do
        policies = Module.new do
          extend Sequel::Privacy::PolicyDSL

          policy_factory :AllowIfConfiguredFieldVisible, ->(field) {
            ->(_actor, subject) { allow if subject.public_send(field) == 'visible' }
          }
        end

        test_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
        end

        expect {
          test_class.privacy do
            field :name, policies::AllowIfConfiguredFieldVisible
          end
        }.to raise_error(ArgumentError, /Policy factory AllowIfConfiguredFieldVisible must be called with arguments/)
      end

      it 'prevents changes after finalization' do
        ao = allow_owner_p
        test_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
        end
        test_class.privacy do
          can :view, ao
          finalize!
        end

        expect {
          test_class.privacy do
            can :edit, ao
          end
        }.to raise_error(/Privacy already finalized/)
      end
    end
  end

  describe 'InstanceMethods' do
    let(:test_class) do
      allow_owner = allow_owner_policy
      allow_admin = allow_admin_policy
      deny = deny_policy

      Class.new(Sequel::Model(:privacy_test_items)) do
        plugin :privacy

        policies :view, allow_owner, allow_admin, deny
        policies :edit, allow_owner, deny
        policies :create, allow_admin, deny
      end
    end

    let(:owned_instance) { test_class.new(name: 'Test', owner_id: 1) }
    let(:other_instance) { test_class.new(name: 'Other', owner_id: 99) }

    describe '#for_vc' do
      it 'attaches viewer context to instance' do
        result = owned_instance.for_vc(vc)
        expect(owned_instance.viewer_context).to eq(vc)
      end

      it 'returns self for chaining' do
        result = owned_instance.for_vc(vc)
        expect(result).to eq(owned_instance)
      end
    end

    describe '#viewer_context' do
      it 'returns nil by default' do
        expect(owned_instance.viewer_context).to be_nil
      end

      it 'returns attached viewer context' do
        owned_instance.for_vc(vc)
        expect(owned_instance.viewer_context).to eq(vc)
      end
    end

    describe '#allow?' do
      context 'with owner policies' do
        it 'returns true when actor owns the resource' do
          expect(owned_instance.allow?(vc, :view)).to be true
        end

        it 'returns false when actor does not own the resource' do
          expect(other_instance.allow?(vc, :view)).to be false
        end
      end

      context 'with admin policies' do
        it 'returns true for admin viewer' do
          expect(other_instance.allow?(admin_vc, :view)).to be true
        end

        it 'returns false for non-admin on create' do
          expect(owned_instance.allow?(vc, :create)).to be false
        end

        it 'returns true for admin on create' do
          expect(owned_instance.allow?(admin_vc, :create)).to be true
        end
      end

      context 'with undefined action' do
        it 'returns false' do
          expect(owned_instance.allow?(vc, :nonexistent)).to be false
        end
      end

      context 'with all-powerful viewer context' do
        it 'always returns true' do
          expect(other_instance.allow?(all_powerful_vc, :view)).to be true
          expect(other_instance.allow?(all_powerful_vc, :edit)).to be true
        end
      end
    end

    describe 'field-level privacy' do
      let(:field_class) do
        allow_owner = allow_owner_policy
        deny = deny_policy

        Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy

          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow, deny
          policies :view_secret_field, allow_owner, deny

          protect_field :secret_field
        end
      end

      let(:instance) { field_class.new(name: 'Test', secret_field: 'secret', owner_id: 1) }

      it 'returns field value when policy allows' do
        instance.for_vc(vc)
        expect(instance.secret_field).to eq('secret')
      end

      it 'returns nil when policy denies' do
        other_vc = Sequel::Privacy::ViewerContext.for_actor(TestActor.new(99))
        instance.for_vc(other_vc)
        expect(instance.secret_field).to be_nil
      end

      it 'raises MissingViewerContext when no viewer context attached' do
        expect { instance.secret_field }.to raise_error(Sequel::Privacy::MissingViewerContext)
      end

      it 'returns raw field value without VC when class uses allow_unsafe_access!' do
        allow_owner = allow_owner_policy
        deny = deny_policy

        unsafe_field_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
          allow_unsafe_access!

          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow, deny
          policies :view_secret_field, allow_owner, deny

          protect_field :secret_field
        end

        unsafe_instance = unsafe_field_class.new(name: 'Test', secret_field: 'secret', owner_id: 1)
        expect(unsafe_instance.secret_field).to eq('secret')
      end
    end

    describe '#save with privacy checks' do
      let(:saveable_class) do
        allow_owner = allow_owner_policy
        allow_admin = allow_admin_policy
        deny = deny_policy

        Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy

          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          policies :create, allow_admin, deny
          policies :edit, allow_owner, deny
        end
      end

      after(:each) do
        DB[:privacy_test_items].delete
      end

      it 'allows save when :create policy passes for new record' do
        instance = saveable_class.new(name: 'Test', owner_id: 1)
        instance.for_vc(admin_vc)
        expect { instance.save }.not_to raise_error
      end

      it 'raises Unauthorized when :create policy fails' do
        instance = saveable_class.new(name: 'Test', owner_id: 1)
        instance.for_vc(vc)
        expect { instance.save }.to raise_error(Sequel::Privacy::Unauthorized, /Cannot create/)
      end

      it 'allows save when :edit policy passes for existing record' do
        # Create without privacy check
        instance = saveable_class.create(name: 'Test', owner_id: 1)
        instance.for_vc(vc)
        instance.name = 'Updated'
        expect { instance.save }.not_to raise_error
      end

      it 'raises Unauthorized when :edit policy fails for existing record' do
        instance = saveable_class.create(name: 'Test', owner_id: 99)
        instance.for_vc(vc)
        instance.name = 'Updated'
        expect { instance.save }.to raise_error(Sequel::Privacy::Unauthorized, /Cannot edit/)
      end

      it 'allows save without viewer context (backward compatibility)' do
        instance = saveable_class.new(name: 'Test', owner_id: 1)
        expect { instance.save }.not_to raise_error
      end
    end
  end

  describe 'DatasetMethods' do
    let(:dataset_class) do
      allow_owner = allow_owner_policy
      deny = deny_policy

      Class.new(Sequel::Model(:privacy_test_items)) do
        plugin :privacy
        policies :view, allow_owner, deny
      end
    end

    before(:each) do
      DB[:privacy_test_items].delete
      DB[:privacy_test_items].insert(name: 'Owned', owner_id: 1)
      DB[:privacy_test_items].insert(name: 'Other', owner_id: 99)
      DB[:privacy_test_items].insert(name: 'Another', owner_id: 1)
    end

    after(:each) do
      DB[:privacy_test_items].delete
    end

    describe '#for_vc' do
      it 'filters results based on :view policy' do
        results = dataset_class.for_vc(vc).all
        expect(results.length).to eq(2)
        expect(results.map(&:name)).to contain_exactly('Owned', 'Another')
      end

      it 'attaches viewer context to each result' do
        results = dataset_class.for_vc(vc).all
        results.each do |r|
          expect(r.viewer_context).to eq(vc)
        end
      end

      it 'returns all results for all-powerful VC' do
        results = dataset_class.for_vc(all_powerful_vc).all
        expect(results.length).to eq(3)
      end

      it 'works with additional query conditions' do
        results = dataset_class.for_vc(vc).where(name: 'Owned').all
        expect(results.length).to eq(1)
        expect(results.first.name).to eq('Owned')
      end
    end

    describe 'strict mode enforcement' do
      it 'raises MissingViewerContext when accessing model without VC' do
        expect {
          dataset_class.first
        }.to raise_error(Sequel::Privacy::MissingViewerContext)
      end

      it 'allows access with allow_unsafe_access!' do
        unsafe_class = Class.new(Sequel::Model(:privacy_test_items)) do
          plugin :privacy
          allow_unsafe_access!
          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
        end

        # Should not raise - unsafe access allowed
        result = unsafe_class.first
        expect(result).not_to be_nil
      end

      describe 'allow_unsafe_access! with except:' do
        let(:strict_field_class) do
          allow_owner = allow_owner_policy
          deny = deny_policy

          Class.new(Sequel::Model(:privacy_test_items)) do
            plugin :privacy
            allow_unsafe_access! except: %i[secret_field]

            policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow, deny
            policies :view_secret_field, allow_owner, deny

            protect_field :secret_field
          end
        end

        it 'allows the model to load without VC' do
          strict_field_class.create(name: 'Strict', secret_field: 'shh', owner_id: 1)
          expect { strict_field_class.where(name: 'Strict').first }.not_to raise_error
        end

        it 'still gates fields named in except: when no VC is attached' do
          strict_field_class.create(name: 'Strict', secret_field: 'shh', owner_id: 1)
          loaded = strict_field_class.where(name: 'Strict').first

          expect { loaded.secret_field }.to raise_error(Sequel::Privacy::MissingViewerContext)

          # Sanity: name is not in except: and reads freely.
          expect(loaded.name).to eq('Strict')
        end

        it 'returns the field value when a VC is attached and policy allows' do
          strict_field_class.create(name: 'Strict', secret_field: 'shh', owner_id: 1)
          loaded = strict_field_class.where(name: 'Strict').first
          loaded.for_vc(vc)
          expect(loaded.secret_field).to eq('shh')
        end

        it 'gates plural associations named in except: when no VC' do
          DB.create_table?(:privacy_unsafe_parents) do
            primary_key :id
            String :name
          end
          DB.create_table?(:privacy_unsafe_kids) do
            primary_key :id
            Integer :parent_id
            String :name
          end

          unsafe_kid_class = Class.new(Sequel::Model(:privacy_unsafe_kids)) do
            plugin :privacy
            allow_unsafe_access!
            policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end

          kid_klass = unsafe_kid_class
          parent_class = Class.new(Sequel::Model(:privacy_unsafe_parents)) do
            plugin :privacy
            allow_unsafe_access! except: %i[kids]
            policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow

            one_to_many :kids, class: kid_klass, key: :parent_id
          end

          parent = parent_class.create(name: 'P')
          unsafe_kid_class.create(parent_id: parent.id, name: 'K')
          loaded = parent_class.first

          expect { loaded.kids }.to raise_error(Sequel::Privacy::MissingViewerContext)

          DB.drop_table?(:privacy_unsafe_kids)
          DB.drop_table?(:privacy_unsafe_parents)
        end

        it 'still permits associations not named in except:' do
          DB.create_table?(:privacy_loose_parents) do
            primary_key :id
            String :name
          end
          DB.create_table?(:privacy_loose_kids) do
            primary_key :id
            Integer :parent_id
            String :name
          end

          loose_kid_class = Class.new(Sequel::Model(:privacy_loose_kids)) do
            plugin :privacy
            allow_unsafe_access!
            policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end

          kid_klass = loose_kid_class
          parent_class = Class.new(Sequel::Model(:privacy_loose_parents)) do
            plugin :privacy
            allow_unsafe_access! except: %i[other_assoc]
            policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow

            one_to_many :kids, class: kid_klass, key: :parent_id
          end

          parent = parent_class.create(name: 'P')
          loose_kid_class.create(parent_id: parent.id, name: 'K')
          loaded = parent_class.first

          expect { loaded.kids }.not_to raise_error
          expect(loaded.kids.length).to eq(1)

          DB.drop_table?(:privacy_loose_kids)
          DB.drop_table?(:privacy_loose_parents)
        end
      end
    end
  end

  describe 'policy inheritance' do
    let(:base_class) do
      allow_owner = allow_owner_policy
      deny = deny_policy

      Class.new(Sequel::Model(:privacy_test_items)) do
        plugin :privacy
        policies :view, allow_owner, deny
      end
    end

    let(:child_class) do
      Class.new(base_class) do
        # Inherits :view policy, adds :edit
        policies :edit, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
      end
    end

    it 'inherits parent policies' do
      instance = child_class.new(owner_id: 1)
      expect(instance.allow?(vc, :view)).to be true
    end

    it 'can define additional policies' do
      instance = child_class.new(owner_id: 99)
      expect(instance.allow?(vc, :edit)).to be true
    end

    it 'does not affect parent class' do
      expect(base_class.privacy_policies[:edit]).to be_nil
    end
  end

  describe 'association privacy' do
    # Create association tables
    before(:all) do
      DB.create_table?(:privacy_parents) do
        primary_key :id
        String :name
        Integer :owner_id
      end

      DB.create_table?(:privacy_children) do
        primary_key :id
        String :name
        Integer :parent_id
        Integer :owner_id
      end

      DB.create_table?(:privacy_addresses) do
        primary_key :id
        String :street
        Integer :parent_id
        Integer :owner_id
      end
    end

    after(:all) do
      DB.drop_table?(:privacy_addresses)
      DB.drop_table?(:privacy_children)
      DB.drop_table?(:privacy_parents)
    end

    # Define child model first (needed for associations)
    let(:child_class) do
      allow_owner = allow_owner_policy
      deny = deny_policy

      Class.new(Sequel::Model(:privacy_children)) do
        plugin :privacy
        policies :view, allow_owner, deny
      end
    end

    # Define address model (for one_to_one)
    let(:address_class) do
      allow_owner = allow_owner_policy
      deny = deny_policy

      Class.new(Sequel::Model(:privacy_addresses)) do
        plugin :privacy
        policies :view, allow_owner, deny
      end
    end

    # Define parent model with associations
    let(:parent_class) do
      allow_owner = allow_owner_policy
      deny = deny_policy
      child_klass = child_class
      address_klass = address_class

      Class.new(Sequel::Model(:privacy_parents)) do
        plugin :privacy
        policies :view, allow_owner, deny

        one_to_many :children, class: child_klass, key: :parent_id
        one_to_one :address, class: address_klass, key: :parent_id
      end
    end

    before(:each) do
      DB[:privacy_addresses].delete
      DB[:privacy_children].delete
      DB[:privacy_parents].delete
    end

    describe 'one_to_many associations' do
      it 'attaches the dataset VC through associations defined before the plugin is loaded' do
        protected_child_class = Class.new(Sequel::Model(:privacy_children)) do
          plugin :privacy
          allow_unsafe_access! except: %i[name]

          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
            field :name, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end
        end

        child_klass = protected_child_class
        late_plugin_parent_class = Class.new(Sequel::Model(:privacy_parents)) do
          one_to_many :children, class: child_klass, key: :parent_id

          plugin :privacy
          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end
        end

        parent = late_plugin_parent_class.create(name: 'Parent', owner_id: 1)
        protected_child_class.create(name: 'Child', parent_id: parent.id, owner_id: 1)

        loaded_parent = late_plugin_parent_class.for_vc(vc).all.first
        child = loaded_parent.children.first

        expect(child.viewer_context).to eq(vc)
        expect(child.name).to eq('Child')

        eager_loaded_parent = late_plugin_parent_class.for_vc(vc).eager(:children).all.first
        eager_loaded_child = eager_loaded_parent.associations.fetch(:children).first

        expect(eager_loaded_child.viewer_context).to eq(vc)
      end

      it 'keeps propagating the VC after Sorbet replaces its runtime wrapper' do
        protected_child_class = Class.new(Sequel::Model(:privacy_children)) do
          plugin :privacy
          allow_unsafe_access! except: %i[name]

          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
            field :name, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end
        end

        child_klass = protected_child_class
        signed_parent_class = Class.new(Sequel::Model(:privacy_parents)) do
          extend T::Sig
          one_to_many :children, class: child_klass, key: :parent_id

          sig { returns(T::Array[child_klass]) }
          def children
            super
          end

          plugin :privacy
          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end
        end

        parent = signed_parent_class.create(name: 'Parent', owner_id: 1)
        protected_child_class.create(name: 'Child', parent_id: parent.id, owner_id: 1)

        # The first invocation replaces Sorbet's initial validation wrapper.
        signed_parent_class.for_vc(vc)[parent.id].children

        child = signed_parent_class.for_vc(vc)[parent.id].children.first

        expect(child.viewer_context).to equal(vc)
        expect { child.name }.not_to raise_error
      end

      it 'keeps privacy wrappers ahead of association methods replaced later' do
        replacement_calls = []
        late_parent_class = parent_class

        late_parent_class.define_method(:children) do |*args, &block|
          replacement_calls << :reader
          super(*args, &block)
        end
        late_parent_class.define_method(:children_dataset) do |*args, &block|
          replacement_calls << :dataset
          super(*args, &block)
        end

        parent = late_parent_class.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Child', parent_id: parent.id, owner_id: 1)
        loaded_parent = late_parent_class.for_vc(vc)[parent.id]

        expect(loaded_parent.children.first.viewer_context).to equal(vc)
        expect(loaded_parent.children_dataset.first.viewer_context).to equal(vc)
        expect(replacement_calls).to contain_exactly(:reader, :dataset)
      end

      it 'uses a separate wrapper module for subclass associations' do
        child_klass = child_class
        subclass = Class.new(parent_class) do
          one_to_one :primary_child, class: child_klass, key: :parent_id
        end

        parent_wrapper = parent_class.send(:privacy_association_wrapper)
        subclass_wrapper = subclass.send(:privacy_association_wrapper)

        expect(subclass_wrapper).not_to equal(parent_wrapper)
        expect(subclass.ancestors.first).to equal(subclass_wrapper)

        parent = subclass.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Child', parent_id: parent.id, owner_id: 1)
        loaded_parent = subclass.for_vc(vc)[parent.id]

        expect(loaded_parent.children.first.viewer_context).to equal(vc)
        expect(loaded_parent.primary_child.viewer_context).to equal(vc)
      end

      it 'filters children based on :view policy' do
        # Create parent owned by actor 1
        parent = parent_class.create(name: 'Parent', owner_id: 1)

        # Create children - one owned by actor 1, one by actor 99
        child_class.create(name: 'Owned Child', parent_id: parent.id, owner_id: 1)
        child_class.create(name: 'Other Child', parent_id: parent.id, owner_id: 99)

        # Attach VC and access children
        parent.for_vc(vc)
        children = parent.children

        # Should only see the child owned by actor 1
        expect(children.length).to eq(1)
        expect(children.first.name).to eq('Owned Child')
      end

      it 'raises MissingViewerContext without VC when child model requires it' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Child 1', parent_id: parent.id, owner_id: 1)

        # No VC attached - should raise because child model requires VC
        expect { parent.children }.to raise_error(Sequel::Privacy::MissingViewerContext)
      end

      it 'returns all children without VC when child model allows unsafe access' do
        # Create child class that allows unsafe access
        allow_owner = allow_owner_policy
        deny = deny_policy
        unsafe_child_class = Class.new(Sequel::Model(:privacy_children)) do
          plugin :privacy
          allow_unsafe_access!
          policies :view, allow_owner, deny
        end

        # Create parent class using unsafe child
        child_klass = unsafe_child_class
        unsafe_parent_class = Class.new(Sequel::Model(:privacy_parents)) do
          plugin :privacy
          allow_unsafe_access!
          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          one_to_many :children, class: child_klass, key: :parent_id
        end

        parent = unsafe_parent_class.create(name: 'Parent', owner_id: 1)
        unsafe_child_class.create(name: 'Child 1', parent_id: parent.id, owner_id: 1)
        unsafe_child_class.create(name: 'Child 2', parent_id: parent.id, owner_id: 99)

        # No VC attached - should work because both models allow unsafe access
        children = parent.children
        expect(children.length).to eq(2)
      end

      it 'attaches VC to returned children' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Child', parent_id: parent.id, owner_id: 1)

        parent.for_vc(vc)
        child = parent.children.first

        expect(child.viewer_context).to eq(vc)
      end

      it 'attaches VC to records loaded through the association dataset' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Owned Child', parent_id: parent.id, owner_id: 1)

        parent.for_vc(vc)
        child = parent.children_dataset.first

        expect(child.viewer_context).to eq(vc)
      end

      it 'filters records loaded through the association dataset by :view policy' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Other Child', parent_id: parent.id, owner_id: 99)

        parent.for_vc(vc)

        expect(parent.children_dataset.first).to be_nil
      end

      it 'returns all children for all-powerful VC' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Child 1', parent_id: parent.id, owner_id: 1)
        child_class.create(name: 'Child 2', parent_id: parent.id, owner_id: 99)

        parent.for_vc(all_powerful_vc)
        children = parent.children

        expect(children.length).to eq(2)
      end

      describe 'eager loading' do
        it 'filters eager-loaded children by :view policy' do
          parent = parent_class.create(name: 'Parent', owner_id: 1)
          child_class.create(name: 'Owned Child', parent_id: parent.id, owner_id: 1)
          child_class.create(name: 'Other Child', parent_id: parent.id, owner_id: 99)

          loaded = parent_class.for_vc(vc).eager(:children).all.first
          raw_names = loaded.associations.fetch(:children).map(&:name)
          names = loaded.children.map(&:name)

          expect(raw_names).to contain_exactly('Owned Child', 'Other Child')
          expect(names).to contain_exactly('Owned Child')
        end

        it 'keeps the eager-load marker across thread boundaries' do
          dataset = child_class.for_vc(vc).clone(privacy_eager_load: true, async: true)
          values = {id: 123, name: 'Other Child', parent_id: 456, owner_id: 99}

          child = Thread.new { dataset.row_proc.call(values) }.value

          expect(dataset.opts[:privacy_eager_load]).to be true
          expect(dataset.opts[:async]).to be true
          expect(child).to be_a(child_class)
          expect(child.viewer_context).to equal(vc)
        end

        it 'attaches the VC to each eager-loaded child' do
          parent = parent_class.create(name: 'Parent', owner_id: 1)
          child_class.create(name: 'Owned Child', parent_id: parent.id, owner_id: 1)

          loaded = parent_class.for_vc(vc).eager(:children).all.first
          expect(loaded.children.first.viewer_context).to eq(vc)
        end

        it 'does not raise MissingViewerContext for eager-loaded strict children' do
          parent = parent_class.create(name: 'Parent', owner_id: 1)
          child_class.create(name: 'Child', parent_id: parent.id, owner_id: 1)

          expect {
            parent_class.for_vc(vc).eager(:children).all
          }.not_to raise_error
        end

        it 'returns all eager-loaded children for all-powerful VC' do
          parent = parent_class.create(name: 'Parent', owner_id: 1)
          child_class.create(name: 'Child 1', parent_id: parent.id, owner_id: 1)
          child_class.create(name: 'Child 2', parent_id: parent.id, owner_id: 99)

          loaded = parent_class.for_vc(all_powerful_vc).eager(:children).all.first
          expect(loaded.children.length).to eq(2)
        end

        it 'filters children in strict mode (no allow_unsafe_access)' do
          # parent_class and child_class in this describe block do NOT
          # set allow_unsafe_access!, so this exercises the strict path
          # end-to-end: eager load must propagate VC or Model.call raises.
          parent = parent_class.create(name: 'P', owner_id: 1)
          child_class.create(name: 'Mine', parent_id: parent.id, owner_id: 1)
          child_class.create(name: 'Theirs', parent_id: parent.id, owner_id: 99)

          loaded = parent_class.for_vc(vc).eager(:children).all.first

          expect(loaded.children.map(&:name)).to contain_exactly('Mine')
          expect(loaded.children.first.viewer_context).to eq(vc)
        end

        it 'leaves the parents query compaction intact (filters parents)' do
          # A parent owned by actor 1 (visible) and one owned by 99 (hidden)
          p1 = parent_class.create(name: 'Mine', owner_id: 1)
          parent_class.create(name: 'Theirs', owner_id: 99)
          child_class.create(name: 'Child', parent_id: p1.id, owner_id: 1)

          loaded = parent_class.for_vc(vc).eager(:children).all

          expect(loaded.map(&:name)).to contain_exactly('Mine')
        end
      end
    end

    describe 'one_to_one associations' do
      it 'returns association when :view policy allows' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        address_class.create(street: '123 Main St', parent_id: parent.id, owner_id: 1)

        parent.for_vc(vc)
        address = parent.address

        expect(address).not_to be_nil
        expect(address.street).to eq('123 Main St')
      end

      it 'returns nil when :view policy denies' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        address_class.create(street: '123 Main St', parent_id: parent.id, owner_id: 99)

        parent.for_vc(vc)
        address = parent.address

        expect(address).to be_nil
      end

      it 'raises MissingViewerContext without VC when associated model requires it' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        address_class.create(street: '123 Main St', parent_id: parent.id, owner_id: 99)

        # No VC attached - should raise because address model requires VC
        expect { parent.address }.to raise_error(Sequel::Privacy::MissingViewerContext)
      end

      it 'returns association without VC when associated model allows unsafe access' do
        # Create address class that allows unsafe access
        allow_owner = allow_owner_policy
        deny = deny_policy
        unsafe_address_class = Class.new(Sequel::Model(:privacy_addresses)) do
          plugin :privacy
          allow_unsafe_access!
          policies :view, allow_owner, deny
        end

        # Create parent class using unsafe address
        addr_klass = unsafe_address_class
        unsafe_parent_class = Class.new(Sequel::Model(:privacy_parents)) do
          plugin :privacy
          allow_unsafe_access!
          policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          one_to_one :address, class: addr_klass, key: :parent_id
        end

        parent = unsafe_parent_class.create(name: 'Parent', owner_id: 1)
        unsafe_address_class.create(street: '123 Main St', parent_id: parent.id, owner_id: 99)

        # No VC attached - should work because both models allow unsafe access
        address = parent.address
        expect(address).not_to be_nil
      end

      it 'attaches VC to returned association' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        address_class.create(street: '123 Main St', parent_id: parent.id, owner_id: 1)

        parent.for_vc(vc)
        address = parent.address

        expect(address.viewer_context).to eq(vc)
      end

      it 'returns association for all-powerful VC' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        address_class.create(street: '123 Main St', parent_id: parent.id, owner_id: 99)

        parent.for_vc(all_powerful_vc)
        address = parent.address

        expect(address).not_to be_nil
      end

      describe 'eager loading' do
        it 'filters eager-loaded one_to_one association by :view policy' do
          p1 = parent_class.create(name: 'P1', owner_id: 1)
          p2 = parent_class.create(name: 'P2', owner_id: 1)
          address_class.create(street: 'mine', parent_id: p1.id, owner_id: 1)
          address_class.create(street: 'theirs', parent_id: p2.id, owner_id: 99)

          loaded = parent_class.for_vc(vc).eager(:address).all
          by_name = loaded.each_with_object({}) { |pa, h| h[pa.name] = pa.address }

          expect(by_name['P1']&.street).to eq('mine')
          expect(by_name['P2']).to be_nil
        end

        it 'evaluates ownership through the populated reciprocal without extra queries' do
          owner_through_member = Sequel::Privacy::Policy.create(
            :owner_through_member,
            ->(actor, mailing_address) {
              allow if mailing_address.member.owner_id == actor.id
            }
          )

          mailing_address_class = Class.new(Sequel::Model(:privacy_addresses)) do
            plugin :privacy
            privacy do
              can :view, owner_through_member
            end
          end
          member_class = Class.new(Sequel::Model(:privacy_parents)) do
            plugin :privacy
            privacy do
              can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
            end
          end

          member_class.one_to_one :mailing_address,
            class: mailing_address_class,
            key: :parent_id
          mailing_address_class.many_to_one :member,
            class: member_class,
            key: :parent_id

          mine = member_class.create(name: 'Mine', owner_id: 1)
          theirs = member_class.create(name: 'Theirs', owner_id: 99)
          mailing_address_class.create(street: 'mine', parent_id: mine.id, owner_id: 99)
          mailing_address_class.create(street: 'theirs', parent_id: theirs.id, owner_id: 1)

          sql_logger = Class.new do
            attr_reader :sqls

            def initialize
              @sqls = []
            end

            def info(message)
              @sqls << message
            end
          end.new

          DB.loggers << sql_logger
          begin
            loaded = member_class.for_vc(vc).order(:id).eager(:mailing_address).all
            eager_query_count = sql_logger.sqls.length
            raw_addresses = loaded.map { |member| member.associations.fetch(:mailing_address) }

            expect(raw_addresses.map { |address| address.associations.fetch(:member) }).to eq(loaded)

            by_name = loaded.to_h { |member| [member.name, member.mailing_address] }

            expect(by_name['Mine']&.street).to eq('mine')
            expect(by_name['Theirs']).to be_nil
            expect(eager_query_count).to eq(2)
            expect(sql_logger.sqls.length).to eq(eager_query_count)
          ensure
            DB.loggers.delete(sql_logger)
          end
        end

        it 'defers privacy enforcement through nested eager loading' do
          owner_policy = allow_owner_policy
          nested_address_class = Class.new(Sequel::Model(:privacy_addresses)) do
            plugin :privacy
            privacy do
              can :view, owner_policy
            end
          end
          nested_child_class = Class.new(Sequel::Model(:privacy_children)) do
            plugin :privacy
            privacy do
              can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
            end
          end
          nested_parent_class = Class.new(Sequel::Model(:privacy_parents)) do
            plugin :privacy
            privacy do
              can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
            end
          end

          nested_parent_class.one_to_many :children,
            class: nested_child_class,
            key: :parent_id
          nested_child_class.one_to_one :address,
            class: nested_address_class,
            key: :parent_id,
            primary_key: :parent_id

          parent = nested_parent_class.create(name: 'Parent', owner_id: 1)
          nested_child_class.create(name: 'Child', parent_id: parent.id, owner_id: 1)
          nested_address_class.create(street: 'Hidden', parent_id: parent.id, owner_id: 99)

          loaded = nested_parent_class.for_vc(vc).eager(children: :address).all.first
          child = loaded.children.first

          expect(child.associations.fetch(:address)).to be_a(nested_address_class)
          expect(child.address).to be_nil
        end
      end
    end

    describe 'policy evaluation with associations' do
      # This tests the scenario where a policy needs to access associations
      # to determine access (e.g., "allow if actor is a member of this group")
      it 'clears VC during policy evaluation to allow raw association access' do
        # Create a policy that checks if actor is in the children list
        actor_in_children_policy = Sequel::Privacy::Policy.create(
          :actor_in_children,
          ->(actor, subject) {
            # This accesses the children association during policy evaluation.
            # Without clearing the VC, this would filter children and potentially
            # cause the check to fail incorrectly.
            allow if subject.children.any? { |c| c.owner_id == actor.id }
          }
        )
        deny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny

        # Create a parent class with this policy
        child_klass = child_class
        test_parent_class = Class.new(Sequel::Model(:privacy_parents)) do
          plugin :privacy
          one_to_many :children, class: child_klass, key: :parent_id
        end
        test_parent_class.policies :view, actor_in_children_policy, deny

        # Create parent and children
        parent = test_parent_class.create(name: 'Group', owner_id: 99)
        # Child owned by actor 1 - this is what grants access
        child_class.create(name: 'Actor Child', parent_id: parent.id, owner_id: 1)
        # Child owned by someone else
        child_class.create(name: 'Other Child', parent_id: parent.id, owner_id: 99)

        # Attach VC to parent (as would happen when loaded via for_vc)
        parent.for_vc(vc)

        # The policy should be able to see ALL children (not just actor 1's)
        # to correctly determine that actor 1 IS a member
        expect(parent.allow?(vc, :view)).to be true

        # Verify VC is restored after policy evaluation
        expect(parent.viewer_context).to eq(vc)
      end

      it 'restores VC even if policy raises an error' do
        error_policy = Sequel::Privacy::Policy.create(:error, -> { raise 'Policy error' })
        deny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny

        test_class = Class.new(Sequel::Model(:privacy_parents)) do
          plugin :privacy
        end
        test_class.policies :view, error_policy, deny

        parent = test_class.create(name: 'Test', owner_id: 1)
        parent.for_vc(vc)

        expect { parent.allow?(vc, :view) }.to raise_error('Policy error')
        expect(parent.viewer_context).to eq(vc)
      end

      it 'does not bypass nested non-view checks during policy evaluation' do
        nested_edit_gate = Sequel::Privacy::Policy.create(
          :nested_edit_gate,
          ->(actor, subject) {
            nested_vc = Sequel::Privacy::ViewerContext.for_actor(actor)
            allow if subject.allow?(nested_vc, :edit)
          }
        )
        deny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny

        test_class = Class.new(Sequel::Model(:privacy_parents)) do
          plugin :privacy
        end
        test_class.policies :view, nested_edit_gate, deny
        test_class.policies :edit, deny

        parent = test_class.create(name: 'Task List', owner_id: 1)
        parent.for_vc(vc)

        # If nested non-view checks were bypassed, this would incorrectly allow.
        expect(parent.allow?(vc, :view)).to be false
      end
    end

    describe 'association privacy DSL' do
      # Create tables for association privacy tests
      before(:all) do
        DB.create_table?(:privacy_groups) do
          primary_key :id
          String :name
        end

        DB.create_table?(:privacy_group_members) do
          primary_key :id
          Integer :group_id
          Integer :user_id
        end

        DB.create_table?(:privacy_users) do
          primary_key :id
          String :name
          String :role, default: 'member'
        end
      end

      after(:all) do
        DB.drop_table?(:privacy_group_members)
        DB.drop_table?(:privacy_groups)
        DB.drop_table?(:privacy_users)
      end

      before(:each) do
        DB[:privacy_group_members].delete
        DB[:privacy_groups].delete
        DB[:privacy_users].delete
      end

      # 3-arity policies for testing (actor, subject, direct_object)
      let(:allow_self_add) do
        Sequel::Privacy::Policy.create(:allow_self_add, ->(actor, _group, target_user) {
          allow if actor.id == target_user.id
        })
      end

      let(:allow_self_remove) do
        Sequel::Privacy::Policy.create(:allow_self_remove, ->(actor, _group, target_user) {
          allow if actor.id == target_user.id
        })
      end

      let(:allow_admin_action) do
        Sequel::Privacy::Policy.create(:allow_admin_action, ->(actor, _group, _target) {
          allow if actor.is_role?(:admin)
        })
      end

      let(:allow_admin_remove_all) do
        Sequel::Privacy::Policy.create(:allow_admin_remove_all, ->(actor, _group) {
          allow if actor.is_role?(:admin)
        })
      end

      let(:user_class) do
        Class.new(Sequel::Model(:privacy_users)) do
          include Sequel::Privacy::IActor
          plugin :privacy
          allow_unsafe_access!

          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end

          def is_role?(*roles)
            roles.map(&:to_s).include?(self[:role])
          end
        end
      end

      let(:group_class) do
        self_add = allow_self_add
        self_remove = allow_self_remove
        admin_action = allow_admin_action
        admin_remove_all = allow_admin_remove_all
        user_klass = user_class
        deny = deny_policy

        Class.new(Sequel::Model(:privacy_groups)) do
          plugin :privacy
          allow_unsafe_access!

          many_to_many :members, class: user_klass,
            join_table: :privacy_group_members,
            left_key: :group_id,
            right_key: :user_id

          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow

            association :members do
              can :add, admin_action, self_add
              can :remove, admin_action, self_remove
              can :remove_all, admin_remove_all
            end
          end
        end
      end

      let(:signed_group_class) do
        self_add = allow_self_add
        self_remove = allow_self_remove
        admin_action = allow_admin_action
        admin_remove_all = allow_admin_remove_all
        user_klass = user_class

        Class.new(Sequel::Model(:privacy_groups)) do
          extend T::Sig

          many_to_many :members, class: user_klass,
            join_table: :privacy_group_members,
            left_key: :group_id,
            right_key: :user_id

          sig { params(member: user_klass).returns(T.untyped) }
          def add_member(member)
            super
          end

          sig { params(member: user_klass).returns(T.untyped) }
          def remove_member(member)
            super
          end

          sig { returns(T.untyped) }
          def remove_all_members
            super
          end

          plugin :privacy
          privacy do
            can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow

            association :members do
              can :add, admin_action, self_add
              can :remove, admin_action, self_remove
              can :remove_all, admin_remove_all
            end
          end
        end
      end

      it 'attaches VC to records loaded through many_to_many association datasets' do
        user = user_class.create(name: 'Test User', role: 'member')
        group = group_class.create(name: 'Test Group')
        DB[:privacy_group_members].insert(group_id: group.id, user_id: user.id)

        user_vc = Sequel::Privacy::ViewerContext.for_actor(user)
        group.for_vc(user_vc)
        member = group.members_dataset.first

        expect(member.viewer_context).to eq(user_vc)
      end

      describe 'add_* method' do
        it 'keeps enforcing policy after Sorbet replaces its runtime wrapper' do
          admin = user_class.create(name: 'Admin', role: 'admin')
          actor = user_class.create(name: 'Actor', role: 'member')
          first_target = user_class.create(name: 'First Target', role: 'member')
          denied_target = user_class.create(name: 'Denied Target', role: 'member')
          group = signed_group_class.create(name: 'Test Group')

          admin_vc = Sequel::Privacy::ViewerContext.for_actor(admin)
          signed_group_class.for_vc(admin_vc)[group.id].add_member(first_target)

          actor_vc = Sequel::Privacy::ViewerContext.for_actor(actor)
          loaded_group = signed_group_class.for_vc(actor_vc)[group.id]

          expect { loaded_group.add_member(denied_target) }.to raise_error(Sequel::Privacy::Unauthorized)
          expect(DB[:privacy_group_members].where(group_id: group.id, user_id: denied_target.id).count).to eq(0)
        end

        it 'allows user to add themselves' do
          user = user_class.create(name: 'Test User', role: 'member')
          group = group_class.create(name: 'Test Group')

          user_vc = Sequel::Privacy::ViewerContext.for_actor(user)
          group.for_vc(user_vc)

          expect { group.add_member(user) }.not_to raise_error
          expect(group.members.map(&:id)).to include(user.id)
        end

        it 'denies user from adding another user' do
          user1 = user_class.create(name: 'User 1', role: 'member')
          user2 = user_class.create(name: 'User 2', role: 'member')
          group = group_class.create(name: 'Test Group')

          user1_vc = Sequel::Privacy::ViewerContext.for_actor(user1)
          group.for_vc(user1_vc)

          expect { group.add_member(user2) }.to raise_error(Sequel::Privacy::Unauthorized)
        end

        it 'allows admin to add any user' do
          admin = user_class.create(name: 'Admin', role: 'admin')
          user = user_class.create(name: 'User', role: 'member')
          group = group_class.create(name: 'Test Group')

          admin_vc = Sequel::Privacy::ViewerContext.for_actor(admin)
          group.for_vc(admin_vc)

          expect { group.add_member(user) }.not_to raise_error
          expect(group.members.map(&:id)).to include(user.id)
        end

        it 'allows add without VC when class uses allow_unsafe_access!' do
          user = user_class.create(name: 'Test User', role: 'member')
          group = group_class.create(name: 'Test Group')

          expect { group.add_member(user) }.not_to raise_error
          expect(group.members.map(&:id)).to include(user.id)
        end

        it 'raises MissingViewerContext without VC when class does not allow unsafe access' do
          user_klass = user_class
          strict_group_class = Class.new(Sequel::Model(:privacy_groups)) do
            plugin :privacy
            many_to_many :members, class: user_klass,
              join_table: :privacy_group_members,
              left_key: :group_id,
              right_key: :user_id

            privacy do
              can :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
              association :members do
                can :add, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
              end
            end
          end

          user = user_class.create(name: 'Test User', role: 'member')
          group_id = DB[:privacy_groups].insert(name: 'Strict Group')
          group = strict_group_class.for_vc(all_powerful_vc)[group_id]
          group.instance_variable_set(:@viewer_context, nil)

          expect { group.add_member(user) }.to raise_error(Sequel::Privacy::MissingViewerContext)
        end

        it 'raises Unauthorized with OmniscientVC' do
          user = user_class.create(name: 'Test User', role: 'member')
          group = group_class.create(name: 'Test Group')

          omni_vc = Sequel::Privacy::ViewerContext.omniscient(:test)
          group.for_vc(omni_vc)

          expect { group.add_member(user) }.to raise_error(Sequel::Privacy::Unauthorized)
        end
      end

      describe 'remove_* method' do
        it 'keeps enforcing policy after Sorbet replaces its runtime wrapper' do
          admin = user_class.create(name: 'Admin', role: 'admin')
          actor = user_class.create(name: 'Actor', role: 'member')
          first_target = user_class.create(name: 'First Target', role: 'member')
          denied_target = user_class.create(name: 'Denied Target', role: 'member')
          group = signed_group_class.create(name: 'Test Group')
          DB[:privacy_group_members].insert(group_id: group.id, user_id: first_target.id)
          DB[:privacy_group_members].insert(group_id: group.id, user_id: denied_target.id)

          admin_vc = Sequel::Privacy::ViewerContext.for_actor(admin)
          signed_group_class.for_vc(admin_vc)[group.id].remove_member(first_target)

          actor_vc = Sequel::Privacy::ViewerContext.for_actor(actor)
          loaded_group = signed_group_class.for_vc(actor_vc)[group.id]

          expect { loaded_group.remove_member(denied_target) }.to raise_error(Sequel::Privacy::Unauthorized)
          expect(DB[:privacy_group_members].where(group_id: group.id, user_id: denied_target.id).count).to eq(1)
        end

        it 'allows user to remove themselves' do
          user = user_class.create(name: 'Test User', role: 'member')
          group = group_class.create(name: 'Test Group')
          # Add member directly via join table for setup
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user.id)

          user_vc = Sequel::Privacy::ViewerContext.for_actor(user)
          group.for_vc(user_vc)

          expect { group.remove_member(user) }.not_to raise_error
          expect(group.members.map(&:id)).not_to include(user.id)
        end

        it 'denies user from removing another user' do
          user1 = user_class.create(name: 'User 1', role: 'member')
          user2 = user_class.create(name: 'User 2', role: 'member')
          group = group_class.create(name: 'Test Group')
          # Add member directly via join table for setup
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user2.id)

          user1_vc = Sequel::Privacy::ViewerContext.for_actor(user1)
          group.for_vc(user1_vc)

          expect { group.remove_member(user2) }.to raise_error(Sequel::Privacy::Unauthorized)
        end

        it 'allows admin to remove any user' do
          admin = user_class.create(name: 'Admin', role: 'admin')
          user = user_class.create(name: 'User', role: 'member')
          group = group_class.create(name: 'Test Group')
          # Add member directly via join table for setup
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user.id)

          admin_vc = Sequel::Privacy::ViewerContext.for_actor(admin)
          group.for_vc(admin_vc)

          expect { group.remove_member(user) }.not_to raise_error
          expect(group.members.map(&:id)).not_to include(user.id)
        end

        it 'allows remove without VC when class uses allow_unsafe_access!' do
          user = user_class.create(name: 'User', role: 'member')
          group = group_class.create(name: 'Test Group')
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user.id)

          expect { group.remove_member(user) }.not_to raise_error
          expect(group.members.map(&:id)).not_to include(user.id)
        end
      end

      describe 'remove_all_* method' do
        it 'keeps enforcing policy after Sorbet replaces its runtime wrapper' do
          admin = user_class.create(name: 'Admin', role: 'admin')
          actor = user_class.create(name: 'Actor', role: 'member')
          member = user_class.create(name: 'Member', role: 'member')
          group = signed_group_class.create(name: 'Test Group')
          DB[:privacy_group_members].insert(group_id: group.id, user_id: member.id)

          admin_vc = Sequel::Privacy::ViewerContext.for_actor(admin)
          signed_group_class.for_vc(admin_vc)[group.id].remove_all_members
          DB[:privacy_group_members].insert(group_id: group.id, user_id: member.id)

          actor_vc = Sequel::Privacy::ViewerContext.for_actor(actor)
          loaded_group = signed_group_class.for_vc(actor_vc)[group.id]

          expect { loaded_group.remove_all_members }.to raise_error(Sequel::Privacy::Unauthorized)
          expect(DB[:privacy_group_members].where(group_id: group.id, user_id: member.id).count).to eq(1)
        end

        it 'allows admin to remove all members' do
          admin = user_class.create(name: 'Admin', role: 'admin')
          user1 = user_class.create(name: 'User 1', role: 'member')
          user2 = user_class.create(name: 'User 2', role: 'member')
          group = group_class.create(name: 'Test Group')
          # Add members directly via join table for setup
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user1.id)
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user2.id)

          admin_vc = Sequel::Privacy::ViewerContext.for_actor(admin)
          group.for_vc(admin_vc)

          expect { group.remove_all_members }.not_to raise_error
          expect(group.members).to be_empty
        end

        it 'denies non-admin from removing all members' do
          user = user_class.create(name: 'User', role: 'member')
          group = group_class.create(name: 'Test Group')
          # Add member directly via join table for setup
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user.id)

          user_vc = Sequel::Privacy::ViewerContext.for_actor(user)
          group.for_vc(user_vc)

          expect { group.remove_all_members }.to raise_error(Sequel::Privacy::Unauthorized)
        end

        it 'allows remove_all without VC when class uses allow_unsafe_access!' do
          user = user_class.create(name: 'User', role: 'member')
          group = group_class.create(name: 'Test Group')
          DB[:privacy_group_members].insert(group_id: group.id, user_id: user.id)

          expect { group.remove_all_members }.not_to raise_error
          expect(group.members).to be_empty
        end
      end
    end
  end
end
