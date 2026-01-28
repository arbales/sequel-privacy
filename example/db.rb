# frozen_string_literal: true

require 'sequel'

DB = Sequel.sqlite('example.db')

DB.create_table?(:users) do
  primary_key :id
  String :name, null: false
  String :email, null: false
  String :role, default: 'member'
end

DB.create_table?(:posts) do
  primary_key :id
  foreign_key :author_id, :users, null: false
  String :title, null: false
  TrueClass :published, default: false
end

DB.create_table?(:groups) do
  primary_key :id
  String :name, null: false
end

DB.create_table?(:group_memberships) do
  primary_key :id
  foreign_key :group_id, :groups, null: false
  foreign_key :user_id, :users, null: false
  unique [:group_id, :user_id]
end
