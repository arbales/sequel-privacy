# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sequel::Plugins::Privacy do
  let(:actor) { TestActor.new(1) }
  let(:admin_actor) { TestActor.new(2, roles: [:admin]) }
  let(:vc) { Sequel::Privacy::ViewerContext.for_actor(actor) }
  let(:admin_vc) { Sequel::Privacy::ViewerContext.for_actor(admin_actor) }
  let(:all_powerful_vc) { Sequel::Privacy::ViewerContext.all_powerful('testing') }

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
    Sequel::Privacy::Policy.create(:allow_owner, ->(subject, actor) {
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

      it 'raises error when redefining policies' do
        expect {
          test_class.class_eval do
            policies :view, Sequel::Privacy::BuiltInPolicies::AlwaysAllow
          end
        }.to raise_error(/Cannot redefine policies/)
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

      it 'returns all children for all-powerful VC' do
        parent = parent_class.create(name: 'Parent', owner_id: 1)
        child_class.create(name: 'Child 1', parent_id: parent.id, owner_id: 1)
        child_class.create(name: 'Child 2', parent_id: parent.id, owner_id: 99)

        parent.for_vc(all_powerful_vc)
        children = parent.children

        expect(children.length).to eq(2)
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
    end

    describe 'policy evaluation with associations' do
      # This tests the scenario where a policy needs to access associations
      # to determine access (e.g., "allow if actor is a member of this group")
      it 'clears VC during policy evaluation to allow raw association access' do
        # Create a policy that checks if actor is in the children list
        actor_in_children_policy = Sequel::Privacy::Policy.create(
          :actor_in_children,
          ->(subject, actor) {
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
    end
  end
end
