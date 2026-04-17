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
      host_module.policy(:AllowSelf, ->(subject, actor) { :allow if subject == actor })

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
  end
end
