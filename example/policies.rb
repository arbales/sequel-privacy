# frozen_string_literal: true

require 'sequel-privacy'

module P
  extend Sequel::Privacy::PolicyDSL

  AlwaysDeny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny

  # Policies without parameters could check only global environment
  # factors, or could be useful for something like a truly public
  # object.
  policy :AllowAnyone, -> { allow }
  policy :AllowOnSundays, -> { allow if DateTime.now.sunday? }

  # Use `allow_anonymous` to prevent policies from auto-denying when the actor is nil.
  # This is useful for policies that aren't actor-dependant.
  policy :AllowIfPublished, ->(_actor, subject) { allow if subject.published },
         allow_anonymous: true,
         cache_by: :subject

  # Actor-only role checks.
  policy :AllowAdmins, ->(actor) { allow if actor.is_role?(:admin) }, cacheable: true
  policy :AllowMembers, ->(actor) { allow if actor.is_role?(:member, :admin) }, cacheable: true

  # Use `single_match` to mark policies for which there is only one valid combination of subject and actor.
  policy :AllowSelf, ->(actor, subject) { allow if subject.id == actor.id }, single_match: true
  policy :AllowAuthor, ->(actor, subject) { allow if subject.author_id == actor.id }, single_match: true

  policy :AllowGroupAdmin, ->(actor, _group, _target_user) {
    allow if actor.is_role?(:admin)
  }

  policy :AllowSelfJoin, ->(actor, _group, target_user) {
    allow if actor.id == target_user.id
  }, single_match: true

  policy :AllowSelfRemove, ->(actor, _group, target_user) {
    allow if actor.id == target_user.id
  }, single_match: true
end
