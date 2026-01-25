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
      vc = described_class.all_powerful('testing')
      expect(vc).to be_a(Sequel::Privacy::AllPowerfulVC)
    end

    it 'stores the reason' do
      vc = described_class.all_powerful('testing')
      expect(vc.reason).to eq('testing')
    end

    it 'logs the creation' do
      logger = double('logger')
      allow(Sequel::Privacy).to receive(:logger).and_return(logger)
      expect(logger).to receive(:info).with(/Creating all-powerful viewer context: testing/)
      described_class.all_powerful('testing')
    end

    it 'does not fail when no logger is configured' do
      allow(Sequel::Privacy).to receive(:logger).and_return(nil)
      expect { described_class.all_powerful('testing') }.not_to raise_error
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
  let(:vc) { described_class.new('test reason') }

  it 'is a ViewerContext' do
    expect(vc).to be_a(Sequel::Privacy::ViewerContext)
  end

  it 'requires a reason' do
    expect { described_class.new }.to raise_error(ArgumentError)
  end

  it 'stores the reason' do
    expect(vc.reason).to eq('test reason')
  end

  it 'does not have an actor method' do
    expect(vc).not_to respond_to(:actor)
  end
end
