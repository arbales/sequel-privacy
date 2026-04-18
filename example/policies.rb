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

  # State-gate policies examine only the subject. They declare
  # `allow_anonymous: true` so that logged-out viewers can still pass
  # through (a 2-arg policy would otherwise auto-deny for nil actor).
  policy :AllowIfPublished, ->(_actor, subject) { allow if subject.published },
    allow_anonymous: true,
    cache_by: :subject

  # Actor-only role checks. Arity 1 caches per-actor — one entry shared
  # across every subject being checked.
  policy :AllowAdmins, ->(actor) { allow if actor.is_role?(:admin) }, cacheable: true
  policy :AllowMembers, ->(actor) { allow if actor.is_role?(:member, :admin) }, cacheable: true

  # Ownership / self checks examine both actor and subject.
  policy :AllowSelf, ->(actor, subject) { allow if subject.id == actor.id }, single_match: true
  policy :AllowAuthor, ->(actor, subject) { allow if subject.author_id == actor.id }, single_match: true

  # 3-arity: (actor, subject, direct_object) — auto-denies for anonymous.
  # Used for Group#add_member and Group#remove_member where:
  #   actor = the user performing the action
  #   subject = the group
  #   direct_object = the user being added/removed

  # Allow group admins to add/remove anyone (would check a group_admins table in real app)
  policy :AllowGroupAdmin, ->(actor, _group, _target_user) {
    allow if actor.is_role?(:admin)
  }

  # Allow users to add themselves to a group
  policy :AllowSelfJoin, ->(actor, _group, target_user) {
    allow if actor.id == target_user.id
  }, single_match: true

  # Allow users to remove themselves from a group
  policy :AllowSelfRemove, ->(actor, _group, target_user) {
    allow if actor.id == target_user.id
  }, single_match: true
end
