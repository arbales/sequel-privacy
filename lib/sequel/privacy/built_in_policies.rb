# typed: true
# frozen_string_literal: true

module Sequel
  module Privacy
    module BuiltInPolicies
      # Always deny access. You should specify this policy at the end of every chain, but the framework
      # currently appends it. This could change; I'm not sure about this yet.
      AlwaysDeny = Policy.create(
        :AlwaysDeny,
        -> { :deny },
        'In the absence of other rules, this content is hidden.',
        cacheable: true
      )

      AlwaysAllow = Policy.create(
        :AlwaysAllow,
        -> { :allow },
        'Always allow access.',
        cacheable: true
      )

      # Pass and log - useful for debugging policy chains.
      PassAndLog = Policy.create(
        :PassAndLog,
        ->(actor, subject) {
          Sequel::Privacy::Enforcer.logger&.info("PassAndLog: #{subject.class} for actor #{actor.id}")
          :pass
        },
        'Log and pass to next policy.',
        cacheable: false
      )
    end
  end
end
