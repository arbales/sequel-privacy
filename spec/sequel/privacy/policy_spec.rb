# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sequel::Privacy::Policy do
  describe '.create' do
    it 'creates a policy with a name' do
      policy = described_class.create(:test_policy, -> { :allow })
      expect(policy.policy_name).to eq('test_policy')
    end

    it 'creates a policy with a comment' do
      policy = described_class.create(:test_policy, -> { :allow }, 'A test comment')
      expect(policy.comment).to eq('A test comment')
    end

    it 'creates a cacheable policy by default' do
      policy = described_class.create(:test_policy, -> { :allow })
      expect(policy.cacheable?).to be true
    end

    it 'creates a non-cacheable policy when specified' do
      policy = described_class.create(:test_policy, -> { :allow }, cacheable: false)
      expect(policy.cacheable?).to be false
    end

    it 'creates a non-single-match policy by default' do
      policy = described_class.create(:test_policy, -> { :allow })
      expect(policy.single_match?).to be false
    end

    it 'creates a single-match policy when specified' do
      policy = described_class.create(:test_policy, -> { :allow }, single_match: true)
      expect(policy.single_match?).to be true
    end
  end

  describe '#setup' do
    it 'configures the policy' do
      policy = described_class.new { :allow }
      policy.setup(
        policy_name: :configured_policy,
        comment: 'Configured comment',
        cacheable: true,
        single_match: true
      )

      expect(policy.policy_name).to eq('configured_policy')
      expect(policy.comment).to eq('Configured comment')
      expect(policy.cacheable?).to be true
      expect(policy.single_match?).to be true
    end

    it 'freezes the policy after setup' do
      policy = described_class.new { :allow }
      policy.setup(policy_name: :test)

      expect { policy.setup(policy_name: :another) }.to raise_error(/frozen/)
    end

    it 'returns self for chaining' do
      policy = described_class.new { :allow }
      result = policy.setup(policy_name: :test)
      expect(result).to be policy
    end
  end

  describe 'arity detection' do
    it 'detects 0-arity policies' do
      policy = described_class.new { :allow }
      expect(policy.arity).to eq(0)
    end

    it 'detects 1-arity policies' do
      policy = described_class.new { |actor| :allow }
      expect(policy.arity).to eq(1)
    end

    it 'detects 2-arity policies' do
      policy = described_class.new { |subject, actor| :allow }
      expect(policy.arity).to eq(2)
    end

    it 'detects 3-arity policies' do
      policy = described_class.new { |subject, actor, direct_object| :allow }
      expect(policy.arity).to eq(3)
    end
  end
end
