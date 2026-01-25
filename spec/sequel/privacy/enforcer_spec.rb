# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sequel::Privacy::Enforcer do
  let(:actor) { TestActor.new(1) }
  let(:vc) { Sequel::Privacy::ViewerContext.for_actor(actor) }
  let(:subject_obj) { double('subject', id: 100, class: 'TestSubject') }

  let(:allow_policy) { Sequel::Privacy::BuiltInPolicies::AlwaysAllow }
  let(:deny_policy) { Sequel::Privacy::BuiltInPolicies::AlwaysDeny }
  let(:pass_policy) { Sequel::Privacy::Policy.create(:pass, -> { pass }) }

  describe '.enforce' do
    context 'with AllPowerfulVC' do
      let(:all_powerful_vc) { Sequel::Privacy::ViewerContext.all_powerful('testing') }

      it 'always returns true' do
        result = described_class.enforce([deny_policy], subject_obj, all_powerful_vc)
        expect(result).to be true
      end
    end

    context 'with normal viewer context' do
      it 'returns true when first policy allows' do
        result = described_class.enforce([allow_policy, deny_policy], subject_obj, vc)
        expect(result).to be true
      end

      it 'returns false when policy denies' do
        result = described_class.enforce([deny_policy], subject_obj, vc)
        expect(result).to be false
      end

      it 'passes through to next policy on pass' do
        result = described_class.enforce([pass_policy, allow_policy, deny_policy], subject_obj, vc)
        expect(result).to be true
      end

      it 'returns false when all policies pass (implicit deny)' do
        result = described_class.enforce([pass_policy, pass_policy], subject_obj, vc)
        expect(result).to be false
      end

      it 'returns false for empty policy list' do
        result = described_class.enforce([], subject_obj, vc)
        expect(result).to be false
      end
    end

    context 'with policy arguments' do
      it 'passes actor to 1-arity policies' do
        received_actor = nil
        policy = Sequel::Privacy::Policy.create(:check_actor, ->(a) {
          received_actor = a
          allow
        })

        described_class.enforce([policy, deny_policy], subject_obj, vc)
        expect(received_actor).to eq(actor)
      end

      it 'passes subject and actor to 2-arity policies' do
        received_subject = nil
        received_actor = nil
        policy = Sequel::Privacy::Policy.create(:check_both, ->(s, a) {
          received_subject = s
          received_actor = a
          allow
        })

        described_class.enforce([policy, deny_policy], subject_obj, vc)
        expect(received_subject).to eq(subject_obj)
        expect(received_actor).to eq(actor)
      end

      it 'passes subject, actor, and direct_object to 3-arity policies' do
        # Use a real Sequel::Model instance to satisfy Sorbet runtime type checks
        direct_obj = TestModel.new(name: 'direct')
        received_args = []
        policy = Sequel::Privacy::Policy.create(:check_all, ->(s, a, d) {
          received_args = [s, a, d]
          allow
        })

        described_class.enforce([policy, deny_policy], subject_obj, vc, direct_obj)
        expect(received_args[0]).to eq(subject_obj)
        expect(received_args[1]).to eq(actor)
        expect(received_args[2]).to eq(direct_obj)
      end
    end

    context 'with caching' do
      it 'caches results for cacheable policies' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:cacheable, ->(s, a) {
          call_count += 1
          allow
        }, cacheable: true)

        described_class.enforce([policy, deny_policy], subject_obj, vc)
        described_class.enforce([policy, deny_policy], subject_obj, vc)

        expect(call_count).to eq(1)
      end

      it 'does not cache results for non-cacheable policies' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:non_cacheable, ->(s, a) {
          call_count += 1
          allow
        }, cacheable: false)

        described_class.enforce([policy, deny_policy], subject_obj, vc)
        described_class.enforce([policy, deny_policy], subject_obj, vc)

        expect(call_count).to eq(2)
      end

      it 'uses different cache keys for different subjects' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:cacheable, ->(s, a) {
          call_count += 1
          allow
        }, cacheable: true)

        subject1 = double('subject1', id: 1, class: 'Test')
        subject2 = double('subject2', id: 2, class: 'Test')

        described_class.enforce([policy, deny_policy], subject1, vc)
        described_class.enforce([policy, deny_policy], subject2, vc)

        expect(call_count).to eq(2)
      end
    end

    context 'with single-match optimization' do
      it 'skips evaluation for other subjects after a match' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:single_match, ->(s, a) {
          call_count += 1
          allow if s.id == 1
        }, single_match: true)

        subject1 = double('subject1', id: 1, class: 'Test', hash: 1)
        subject2 = double('subject2', id: 2, class: 'Test', hash: 2)

        # First call should evaluate and match
        result1 = described_class.enforce([policy, deny_policy], subject1, vc)
        expect(result1).to be true
        expect(call_count).to eq(1)

        # Second call should skip (single match already found)
        result2 = described_class.enforce([policy, deny_policy], subject2, vc)
        expect(result2).to be false
        # Policy still called but returns pass, then deny_policy denies
      end
    end

    context 'with invalid policy outcomes' do
      it 'raises InvalidPolicyOutcomeError for invalid return values' do
        policy = Sequel::Privacy::Policy.create(:invalid, -> { :invalid_outcome })

        expect {
          described_class.enforce([policy, deny_policy], subject_obj, vc)
        }.to raise_error(Sequel::Privacy::InvalidPolicyOutcomeError)
      end
    end

  end
end
