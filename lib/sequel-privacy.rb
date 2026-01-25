# typed: strict
# frozen_string_literal: true

require 'sequel'
require 'sorbet-runtime'

module Sequel
  module Privacy
    class << self
      extend T::Sig

      # Configurable logger for privacy enforcement.
      # Set this to your application's logger (e.g., SemanticLogger).
      sig { returns(T.untyped) }
      attr_accessor :logger
    end
  end
end

# Core privacy infrastructure
require_relative 'sequel/privacy/version'
require_relative 'sequel/privacy/errors'
require_relative 'sequel/privacy/i_actor'
require_relative 'sequel/privacy/policy'
require_relative 'sequel/privacy/cache'
require_relative 'sequel/privacy/actions'
require_relative 'sequel/privacy/viewer_context'
require_relative 'sequel/privacy/enforcer'
require_relative 'sequel/privacy/built_in_policies'
require_relative 'sequel/privacy/policy_dsl'

# The plugin is auto-loaded by Sequel when you call `plugin :privacy`
# from lib/sequel/plugins/privacy.rb
