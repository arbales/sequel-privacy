# frozen_string_literal: true

require 'sequel-privacy'

module P
  extend Sequel::Privacy::PolicyDSL

  AlwaysDeny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny

  # Policies without parameters could check only global environment
  # factors, or could be useful for something like a truly public 
  # object.
  policy :AllowAnyone, -> { allow }
  policy :AllowOnSundays, -> { allow if DateTime.now }

  # Policies that receive only the subject can hinge on the state of it.
  # For example, published posts could be viewed by anyone.
  policy :AllowIfPublished, ->(subject) { allow if subject.published }

  # Policies requiring both the subject and the actor will be auto-denied 
  # when a subject isn't available.
  policy :AllowAdmins, ->(_subject, actor) { allow if actor.is_role?(:admin) }, cacheable: true
  policy :AllowMembers, ->(_subject, actor) { allow if actor.is_role?(:member, :admin) }, cacheable: true
  policy :AllowSelf, ->(subject, actor) { allow if subject.id == actor.id }, single_match: true
  policy :AllowAuthor, ->(subject, actor) { allow if subject.author_id == actor.id }, single_match: true

  # 3-arity: (subject, actor, direct_object) - requires actor, auto-deny for anonymous
  # Used for Group#add_member and Group#remove_member where:
  #   subject = the group
  #   actor = the user performing the action
  #   direct_object = the user being added/removed

  # Allow group admins to add/remove anyone (would check a group_admins table in real app)
  policy :AllowGroupAdmin, ->(_group, actor, _target_user) {
    allow if actor.is_role?(:admin)
  }

  # Allow users to add themselves to a group
  policy :AllowSelfJoin, ->(_group, actor, target_user) {
    allow if actor.id == target_user.id
  }, single_match: true

  # Allow users to remove themselves from a group
  policy :AllowSelfRemove, ->(_group, actor, target_user) {
    allow if actor.id == target_user.id
  }, single_match: true
end
