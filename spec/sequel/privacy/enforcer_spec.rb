# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sequel::Privacy::Enforcer do
  let(:actor) { TestActor.new(1) }
  let(:admin_actor) { TestActor.new(2, roles: [:admin]) }
  let(:vc) { Sequel::Privacy::ViewerContext.for_actor(actor) }
  let(:admin_vc) { Sequel::Privacy::ViewerContext.for_actor(admin_actor) }
  let(:subject_obj) { double('subject', id: 100, class: 'TestSubject') }

  let(:allow_policy) { Sequel::Privacy::BuiltInPolicies::AlwaysAllow }
  let(:deny_policy) { Sequel::Privacy::BuiltInPolicies::AlwaysDeny }
  let(:pass_policy) { Sequel::Privacy::Policy.create(:pass, -> { pass }) }

  describe '.enforce' do
    context 'with AllPowerfulVC' do
      let(:all_powerful_vc) { Sequel::Privacy::ViewerContext.all_powerful(:testing) }

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

      it 'passes actor and subject to 2-arity policies' do
        received_actor = nil
        received_subject = nil
        policy = Sequel::Privacy::Policy.create(:check_both, ->(a, s) {
          received_actor = a
          received_subject = s
          allow
        })

        described_class.enforce([policy, deny_policy], subject_obj, vc)
        expect(received_actor).to eq(actor)
        expect(received_subject).to eq(subject_obj)
      end

      it 'passes actor, subject, and direct_object to 3-arity policies' do
        direct_obj = TestModel.new(name: 'direct')
        received_args = []
        policy = Sequel::Privacy::Policy.create(:check_all, ->(a, s, d) {
          received_args = [a, s, d]
          allow
        })

        described_class.enforce([policy, deny_policy], subject_obj, vc, direct_obj)
        expect(received_args[0]).to eq(actor)
        expect(received_args[1]).to eq(subject_obj)
        expect(received_args[2]).to eq(direct_obj)
      end

      context 'with anonymous viewer context' do
        let(:anon_vc) { Sequel::Privacy::ViewerContext.anonymous }

        it 'allows 0-arity policies for anonymous' do
          result = described_class.enforce([allow_policy, deny_policy], subject_obj, anon_vc)
          expect(result).to be true
        end

        it 'auto-denies 1-arity policies for anonymous' do
          policy = Sequel::Privacy::Policy.create(:check_actor, ->(_a) {
            allow # Would allow if called
          })

          result = described_class.enforce([policy, deny_policy], subject_obj, anon_vc)
          expect(result).to be false
        end

        it 'allows anonymous when policy opts in with allow_anonymous: true' do
          policy = Sequel::Privacy::Policy.create(:state_gate, ->(_a, s) {
            allow if s.id == 100
          }, allow_anonymous: true)

          result = described_class.enforce([policy, deny_policy], subject_obj, anon_vc)
          expect(result).to be true
        end

        it 'auto-denies 2-arity policies for anonymous by default' do
          policy = Sequel::Privacy::Policy.create(:check_both, ->(_a, _s) {
            allow # Would allow if called
          })

          result = described_class.enforce([policy, deny_policy], subject_obj, anon_vc)
          expect(result).to be false
        end

        it 'auto-denies 3-arity policies for anonymous' do
          direct_obj = TestModel.new(name: 'direct')
          policy = Sequel::Privacy::Policy.create(:check_all, ->(_a, _s, _d) {
            allow # Would allow if called
          })

          result = described_class.enforce([policy, deny_policy], subject_obj, anon_vc, direct_obj)
          expect(result).to be false
        end
      end
    end

    context 'with caching' do
      it 'caches results for cacheable policies' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:cacheable, ->(a, s) {
          call_count += 1
          allow
        }, cacheable: true)

        described_class.enforce([policy, deny_policy], subject_obj, vc)
        described_class.enforce([policy, deny_policy], subject_obj, vc)

        expect(call_count).to eq(1)
      end

      it 'does not cache results for non-cacheable policies' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:non_cacheable, ->(a, s) {
          call_count += 1
          allow
        }, cacheable: false)

        described_class.enforce([policy, deny_policy], subject_obj, vc)
        described_class.enforce([policy, deny_policy], subject_obj, vc)

        expect(call_count).to eq(2)
      end

      it 'uses different cache keys for different subjects' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:cacheable, ->(a, s) {
          call_count += 1
          allow
        }, cacheable: true)

        subject1 = double('subject1', id: 1, class: 'Test')
        subject2 = double('subject2', id: 2, class: 'Test')

        described_class.enforce([policy, deny_policy], subject1, vc)
        described_class.enforce([policy, deny_policy], subject2, vc)

        expect(call_count).to eq(2)
      end

      context 'with cache_by override' do
        it 'shares cache across subjects when cache_by: :actor' do
          call_count = 0
          policy = Sequel::Privacy::Policy.create(:actor_only, ->(_a, _s) {
            call_count += 1
            allow
          }, cacheable: true, cache_by: :actor)

          subject1 = double('subject1', id: 1, class: 'Test')
          subject2 = double('subject2', id: 2, class: 'Test')

          described_class.enforce([policy, deny_policy], subject1, vc)
          described_class.enforce([policy, deny_policy], subject2, vc)

          expect(call_count).to eq(1)
        end

        it 'separates cache across actors when cache_by: :actor' do
          call_count = 0
          policy = Sequel::Privacy::Policy.create(:actor_only, ->(_a, _s) {
            call_count += 1
            allow
          }, cacheable: true, cache_by: :actor)

          described_class.enforce([policy, deny_policy], subject_obj, vc)
          described_class.enforce([policy, deny_policy], subject_obj, admin_vc)

          expect(call_count).to eq(2)
        end

        it 'excludes direct_object from the key when cache_by: :subject on a 3-arg policy' do
          call_count = 0
          policy = Sequel::Privacy::Policy.create(:subject_only, ->(_a, _s, _d) {
            call_count += 1
            allow
          }, cacheable: true, cache_by: :subject)

          direct1 = TestModel.new(name: 'd1')
          direct2 = TestModel.new(name: 'd2')

          described_class.enforce([policy, deny_policy], subject_obj, vc, direct1)
          described_class.enforce([policy, deny_policy], subject_obj, vc, direct2)

          expect(call_count).to eq(1)
        end

        it 'accepts an array of keys' do
          call_count = 0
          policy = Sequel::Privacy::Policy.create(:combined, ->(_a, _s) {
            call_count += 1
            allow
          }, cacheable: true, cache_by: %i[actor subject])

          subject1 = double('subject1', id: 1, class: 'Test')
          subject2 = double('subject2', id: 2, class: 'Test')

          described_class.enforce([policy, deny_policy], subject1, vc)
          described_class.enforce([policy, deny_policy], subject1, vc)  # hit
          described_class.enforce([policy, deny_policy], subject2, vc)  # miss

          expect(call_count).to eq(2)
        end

        it 'rejects unknown cache_by keys at policy creation' do
          expect {
            Sequel::Privacy::Policy.create(:bad, -> { allow }, cache_by: :bogus)
          }.to raise_error(ArgumentError, /Invalid cache_by key/)
        end
      end
    end

    context 'with single-match optimization' do
      it 'skips evaluation for other subjects after a match' do
        call_count = 0
        policy = Sequel::Privacy::Policy.create(:single_match, ->(a, s) {
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

    context 'with 3-arity policies (direct object)' do
      let(:membership) { double('membership', user_id: 1, group_id: 10, class: 'GroupMembership') }
      let(:other_membership) { double('other_membership', user_id: 99, group_id: 10, class: 'GroupMembership') }
      let(:group) { TestModel.new(name: 'Test Group') }

      # Policy: allow user to remove their own membership
      let(:allow_self_membership) do
        Sequel::Privacy::Policy.create(:allow_self_membership, ->(a, m, _g) {
          allow if m.user_id == a.id
        }, single_match: true)
      end

      # Policy: allow admins to remove any membership
      let(:allow_admin_delete) do
        Sequel::Privacy::Policy.create(:allow_admin_delete, ->(a, _m, _g) {
          allow if a.is_role?(:admin)
        })
      end

      it 'allows user to delete their own membership' do
        result = described_class.enforce(
          [allow_self_membership, deny_policy],
          membership,
          vc,
          group
        )
        expect(result).to be true
      end

      it 'denies user from deleting another users membership' do
        result = described_class.enforce(
          [allow_self_membership, deny_policy],
          other_membership,
          vc,
          group
        )
        expect(result).to be false
      end

      it 'allows admin to delete any membership' do
        result = described_class.enforce(
          [allow_self_membership, allow_admin_delete, deny_policy],
          other_membership,
          admin_vc,
          group
        )
        expect(result).to be true
      end

      it 'combines policies correctly for delete permission' do
        # User can delete own membership
        result1 = described_class.enforce(
          [allow_self_membership, allow_admin_delete, deny_policy],
          membership,
          vc,
          group
        )
        expect(result1).to be true

        # User cannot delete others membership (not admin)
        result2 = described_class.enforce(
          [allow_self_membership, allow_admin_delete, deny_policy],
          other_membership,
          vc,
          group
        )
        expect(result2).to be false

        # Admin can delete any membership
        result3 = described_class.enforce(
          [allow_self_membership, allow_admin_delete, deny_policy],
          other_membership,
          admin_vc,
          group
        )
        expect(result3).to be true
      end
    end

  end
end
