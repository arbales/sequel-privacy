# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sequel::Privacy::ViewerContext do
  let(:actor) { TestActor.new(1) }

  describe '.for_actor' do
    it 'creates an ActorVC' do
      vc = described_class.for_actor(actor)
      expect(vc).to be_a(Sequel::Privacy::ActorVC)
    end

    it 'stores the actor' do
      vc = described_class.for_actor(actor)
      expect(vc.actor).to eq(actor)
    end
  end

  describe '.for_api_actor' do
    it 'creates an APIVC' do
      vc = described_class.for_api_actor(actor)
      expect(vc).to be_a(Sequel::Privacy::APIVC)
    end

    it 'stores the actor' do
      vc = described_class.for_api_actor(actor)
      expect(vc.actor).to eq(actor)
    end
  end

  describe '.all_powerful' do
    it 'creates an AllPowerfulVC' do
      vc = described_class.all_powerful(:testing)
      expect(vc).to be_a(Sequel::Privacy::AllPowerfulVC)
    end

    it 'stores the reason' do
      vc = described_class.all_powerful(:testing)
      expect(vc.reason).to eq(:testing)
    end

    it 'logs the creation' do
      logger = double('logger')
      allow(Sequel::Privacy).to receive(:logger).and_return(logger)
      expect(logger).to receive(:info).with(/Creating all-powerful viewer context: testing/)
      described_class.all_powerful(:testing)
    end

    it 'does not fail when no logger is configured' do
      allow(Sequel::Privacy).to receive(:logger).and_return(nil)
      expect { described_class.all_powerful(:testing) }.not_to raise_error
    end
  end
end

RSpec.describe Sequel::Privacy::ActorVC do
  let(:actor) { TestActor.new(42) }
  let(:vc) { described_class.new(actor) }

  it 'provides access to the actor' do
    expect(vc.actor).to eq(actor)
  end

  it 'delegates id to actor' do
    expect(vc.actor.id).to eq(42)
  end
end

RSpec.describe Sequel::Privacy::AllPowerfulVC do
  let(:vc) { described_class.new(:test_reason) }

  it 'is a ViewerContext' do
    expect(vc).to be_a(Sequel::Privacy::ViewerContext)
  end

  it 'requires a reason' do
    expect { described_class.new }.to raise_error(ArgumentError)
  end

  it 'stores the reason' do
    expect(vc.reason).to eq(:test_reason)
  end

  it 'does not have an actor method' do
    expect(vc).not_to respond_to(:actor)
  end
end

RSpec.describe Sequel::Privacy::TransientViewerContext do
  let(:vc) { Sequel::Privacy::ViewerContext.omniscient(:bootstrap) }

  describe '#use' do
    it 'yields the context and its reason' do
      expect { |b| vc.use(&b) }.to yield_with_args(vc, :bootstrap)
    end

    it 'returns the block value' do
      expect(vc.use { |_vc, _reason| :loaded }).to eq(:loaded)
    end

    it 'invalidates the context once the block returns' do
      vc.use { |_vc, _reason| nil }
      expect(vc).to be_invalidated
    end

    it 'invalidates the context even when the block raises' do
      expect { vc.use { |_vc, _reason| raise 'boom' } }.to raise_error('boom')
      expect(vc).to be_invalidated
    end

    it 'is available on all-powerful contexts' do
      all_powerful = Sequel::Privacy::ViewerContext.all_powerful(:migration)
      all_powerful.use { |_vc, _reason| nil }

      expect(all_powerful).to be_invalidated
    end
  end

  describe '#invalidate!' do
    it 'is idempotent' do
      expect { 2.times { vc.invalidate! } }.not_to raise_error
      expect(vc).to be_invalidated
    end

    it 'makes assert_usable! raise' do
      vc.invalidate!
      expect { vc.assert_usable! }.to raise_error(Sequel::Privacy::InvalidatedViewerContext, /OmniscientVC/)
    end

    it 'leaves a fresh context usable' do
      expect(vc).not_to be_invalidated
      expect { vc.assert_usable! }.not_to raise_error
    end
  end
end
