#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'models'

Post.dataset.delete
User.dataset.delete

alice = User.create(name: 'Alice', email: 'alice@example.com', role: 'admin')
bob = User.create(name: 'Bob', email: 'bob@example.com', role: 'member')
carol = User.create(name: 'Carol', email: 'carol@example.com', role: 'member')

Post.create(title: 'Published Post', published: true, author_id: bob.id)
Post.create(title: 'Draft Post', published: false, author_id: bob.id)

puts "Users: Alice (admin, id=#{alice.id}), Bob (member, id=#{bob.id}), Carol (member, id=#{carol.id})"
