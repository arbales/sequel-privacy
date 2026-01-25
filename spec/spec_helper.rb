# typed: false
# frozen_string_literal: true

require 'bundler/setup'
require 'sequel'
require 'sequel-privacy'

# Use an in-memory SQLite database for testing
DB = Sequel.sqlite

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed

  # Clear privacy caches between tests
  config.before(:each) do
    Sequel::Privacy.cache.clear
    Sequel::Privacy.single_matches.clear
  end
end

# Test actor implementation
class TestActor
  include Sequel::Privacy::IActor

  attr_reader :id, :roles

  def initialize(id, roles: [])
    @id = id
    @roles = roles
  end

  def is_role?(*check_roles)
    (roles & check_roles).any?
  end
end

# Create a test model table and class for integration tests
DB.create_table?(:test_models) do
  primary_key :id
  String :name
  Integer :owner_id
end

class TestModel < Sequel::Model(:test_models)
  plugin :privacy
end
