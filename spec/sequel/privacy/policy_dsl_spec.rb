# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sequel::Privacy::PolicyDSL do
  let(:host_module) do
    Module.new.tap { |m| m.extend(described_class) }
  end

  describe '#policy' do
    it 'defines a Policy as a constant on the extending module' do
      host_module.policy(:AllowAll, -> { :allow })

      expect(host_module.const_defined?(:AllowAll)).to be true
      expect(host_module.const_get(:AllowAll)).to be_a(Sequel::Privacy::Policy)
    end

    it 'sets the policy_name from the constant name' do
      host_module.policy(:AllowAll, -> { :allow })
      expect(host_module::AllowAll.policy_name).to eq('AllowAll')
    end

    it 'forwards the comment to the policy' do
      host_module.policy(:AllowAll, -> { :allow }, 'Permit everything')
      expect(host_module::AllowAll.comment).to eq('Permit everything')
    end

    it 'defaults comment to nil' do
      host_module.policy(:AllowAll, -> { :allow })
      expect(host_module::AllowAll.comment).to be_nil
    end

    it 'defaults cacheable to true' do
      host_module.policy(:AllowAll, -> { :allow })
      expect(host_module::AllowAll.cacheable?).to be true
    end

    it 'forwards cacheable: false' do
      host_module.policy(:AllowAll, -> { :allow }, cacheable: false)
      expect(host_module::AllowAll.cacheable?).to be false
    end

    it 'defaults single_match to false' do
      host_module.policy(:AllowAll, -> { :allow })
      expect(host_module::AllowAll.single_match?).to be false
    end

    it 'forwards single_match: true' do
      host_module.policy(:AllowAll, -> { :allow }, single_match: true)
      expect(host_module::AllowAll.single_match?).to be true
    end

    it 'preserves the lambda body so the policy is invocable' do
      host_module.policy(:AllowSelf, ->(actor, subject) { :allow if subject == actor })

      policy = host_module::AllowSelf
      expect(policy.arity).to eq(2)
      expect(policy.call(:x, :x)).to eq(:allow)
      expect(policy.call(:x, :y)).to be_nil
    end

    it 'allows multiple policies on the same module' do
      host_module.policy(:AllowAll, -> { :allow })
      host_module.policy(:DenyAll, -> { :deny })

      expect(host_module::AllowAll).not_to eq(host_module::DenyAll)
      expect(host_module::AllowAll.policy_name).to eq('AllowAll')
      expect(host_module::DenyAll.policy_name).to eq('DenyAll')
    end

    it 'defines policies on nested modules' do
      root = Module.new
      groups = Module.new do
        extend Sequel::Privacy::PolicyDSL

        policy :AllowGroups, -> { :allow }
      end
      root.const_set(:Groups, groups)

      expect(root::Groups::AllowGroups).to be_a(Sequel::Privacy::Policy)
      expect(root::Groups::AllowGroups.policy_name).to eq('AllowGroups')
      expect(root::Groups::AllowGroups.call).to eq(:allow)
    end
  end

  describe '#policy_factory' do
    it 'defines a PolicyFactory as a constant on the extending module' do
      host_module.policy_factory(:AllowField, ->(field) { ->(_actor, subject) { :allow if subject.public_send(field) } })

      expect(host_module.const_defined?(:AllowField)).to be true
      expect(host_module.const_get(:AllowField)).to be_a(Sequel::Privacy::PolicyFactory)
    end

    it 'defines a callable module method that returns a Policy' do
      host_module.policy_factory(:AllowField, ->(field) { ->(_actor, subject) { :allow if subject.public_send(field) } })

      policy = host_module::AllowField(:visible)

      expect(policy).to be_a(Sequel::Privacy::Policy)
      expect(policy.policy_name).to eq('AllowField(:visible)')
      expect(policy.arity).to eq(2)
    end

    it 'forwards policy options to produced policies' do
      host_module.policy_factory(
        :AllowField,
        ->(_field) { ->(_actor, _subject) { :allow } },
        'Permit based on a configured field',
        cacheable: false,
        single_match: true,
        cache_by: :actor,
        allow_anonymous: true
      )

      policy = host_module::AllowField(:visible)

      expect(policy.comment).to eq('Permit based on a configured field')
      expect(policy.cacheable?).to be false
      expect(policy.single_match?).to be true
      expect(policy.cache_by).to eq([:actor])
      expect(policy.allow_anonymous?).to be true
    end

    it 'raises when the factory does not return a Proc' do
      host_module.policy_factory(:InvalidFactory, ->(_field) { :allow })

      expect {
        host_module::InvalidFactory(:visible)
      }.to raise_error(ArgumentError, /must return a Proc/)
    end

    it 'defines callable policy factories on nested modules' do
      root = Module.new
      groups = Module.new do
        extend Sequel::Privacy::PolicyDSL

        policy_factory :AllowField, ->(field) { ->(_actor, subject) { :allow if subject.public_send(field) } }
      end
      root.const_set(:Groups, groups)

      policy = root::Groups::AllowField(:visible)

      expect(policy).to be_a(Sequel::Privacy::Policy)
      expect(policy.policy_name).to eq('AllowField(:visible)')
    end
  end
end
