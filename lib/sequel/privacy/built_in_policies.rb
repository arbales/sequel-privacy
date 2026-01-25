# typed: false
# frozen_string_literal: true

module Sequel
  module Privacy
    # Built-in policies that ship with the gem.
    # Applications should define their own policies using PolicyDSL.
    module BuiltInPolicies
      # Always deny access. Should be the last policy in every chain (fail-secure).
      AlwaysDeny = Policy.create(
        :AlwaysDeny,
        -> { :deny },
        'In the absence of other rules, this content is hidden.',
        cacheable: true
      )

      # Always allow access. Use sparingly.
      AlwaysAllow = Policy.create(
        :AlwaysAllow,
        -> { :allow },
        'Always allow access.',
        cacheable: true
      )

      # Pass and log - useful for debugging policy chains.
      PassAndLog = Policy.create(
        :PassAndLog,
        ->(subject, actor) {
          Sequel::Privacy::Enforcer.logger&.info("PassAndLog: #{subject.class} for actor #{actor.id}")
          :pass
        },
        'Log and pass to next policy.',
        cacheable: false
      )
    end
  end
end
