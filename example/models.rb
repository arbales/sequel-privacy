# frozen_string_literal: true

require_relative 'db'
require_relative 'policies'

class User < Sequel::Model
  include Sequel::Privacy::IActor

  plugin :privacy

  one_to_many :posts, key: :author_id

  privacy do
    can :view, P::AllowMembers
    can :edit, P::AllowSelf, P::AllowAdmins

    field :email, P::AllowSelf, P::AllowAdmins
  end

  def is_role?(*roles)
    roles.map(&:to_s).include?(role)
  end
end

class Post < Sequel::Model
  plugin :privacy

  many_to_one :author, class: :User

  privacy do
    can :view, P::AllowIfPublished, P::AllowAuthor, P::AllowAdmins
    can :edit, P::AllowAuthor, P::AllowAdmins
    can :create, P::AllowMembers
  end
end

class Group < Sequel::Model
  plugin :privacy

  one_to_many :memberships, class: :GroupMembership
  many_to_many :members, class: :User,
    join_table: :group_memberships,
    left_key: :group_id,
    right_key: :user_id

  privacy do
    can :view, P::AllowMembers
    can :edit, P::AllowAdmins
    can :create, P::AllowAdmins

    # Association-level policies for member management
    association :members do
      can :add, P::AllowGroupAdmin, P::AllowSelfJoin
      can :remove, P::AllowGroupAdmin, P::AllowSelfRemove
      can :remove_all, P::AllowGroupAdmin
    end
  end
end

class GroupMembership < Sequel::Model
  plugin :privacy

  many_to_one :group
  many_to_one :user

  privacy do
    can :view, P::AllowMembers
  end
end
