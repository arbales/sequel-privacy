# Sequel::Privacy

A Sequel plugin that allows you to define policies that are executed when your models are loaded, created or mutated. 
Supports field-level policies to protect data based on actor/viewers' relationships to given models.

## Installation

Add to your Gemfile:

```ruby
gem 'sequel-privacy'
```

Then require it after Sequel:

```ruby
require 'sequel'
require 'sequel-privacy'
```

## Quick Start

### 1. Define Your Policy Module

```ruby
# policies/base.rb
module P
  extend Sequel::Privacy::PolicyDSL

  AlwaysDeny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny
  AlwaysAllow = Sequel::Privacy::BuiltInPolicies::AlwaysAllow
  PassAndLog = Sequel::Privacy::BuiltInPolicies::PassAndLog

  policy :AllowIfPublished, ->(subject) {
    allow if subject.published
  }

  policy :AllowAdmins, ->(_subject, actor) {
    allow if actor.is_role?(:admin)
  }, 'Allow admin users', cacheable: true
  
  policy :AllowMembers, ->(_subject, actor) {
    allow if actor.is_role?(:member)
  }, cacheable: true

  policy :AllowSelf, ->(subject, actor) {
    allow if subject == actor
  }, 'Allow if subject is the actor', single_match: true  
  
  policy :AllowFriendsOfSubject, ->(subject, actor) {
    allow if subject.includes_friend?(actor)
  }
end
```

### 2. Add Privacy to Your Models

```ruby
class Member < Sequel::Model
  plugin :privacy

  privacy do
    # Define who can view this model; be strategic about the order of your policies so that You
    # don't evaluate ones you don't need to.
    can :view, P::AllowSelf, P::AllowMembers
    can :edit, P::AllowSelf, P::AllowAdmins
    can :create, P::AllowAdmins

    field :email, P::AllowMembers
    field :phone, P::AllowSelf, P::AllowFriendsOfSubject, P::AllowAdmins
  end
end
```

The `privacy` block provides:
- `can :action, *policies` - Define policies for an action (`:view`, `:edit`, `:create`, etc.)
- `field :name, *policies` - Protect a field (auto-creates `:view_#{field}` policy)
- `finalize!` - Prevent further modifications to privacy settings

`AlwaysDeny` is automatically appended to all policy chains (fail-secure by default).

### 3. Query with Privacy Enforcement

```ruby
# Create a viewer context
vc = Sequel::Privacy::ViewerContext.for_actor(current_user)

# Query - results are automatically filtered by :view policy
members = Member.for_vc(vc).where(org_id: 1).all

# Check permissions explicitly
member.allow?(vc, :view)  # => true/false
member.allow?(vc, :edit)  # => true/false

# Protected fields return nil if denied
member.email  # => nil if :view_email denies
member.phone  # => nil if :view_phone denies
```

## Policy Definition

Policies are lambdas that execute in the context of an `Actions` struct, giving access to `allow`, `deny`, and `pass` outcome methods, as well as the `all` combinator. Policies accept up to three parameters: `actor`, `subject` & `actor` or `subject`, `actor` and `direct_object`.


```ruby

policy :AlwaysAllow, -> { allow }

policy :AllowIfPublished, ->(subject) {
  allow if subject.published
}

policy :AllowAdmins, ->(_subject, actor) {
  allow if actor.is_role?(:admin)
}

policy :AllowOwner, ->(subject, actor) {
  allow if subject.owner_id == actor.id
}

policy :AllowSelfJoin, ->(_group, actor, target_user) {
  allow if actor.id == target_user.id
}

policy :AllowSelfRemove, ->(_group, actor, target_user) {
  allow if actor.id == target_user.id
}
```

### Policy Return Values

- `allow` - Permits the action, stops evaluation
- `deny` - Rejects the action, stops evaluation
- `pass` (or no explicit return) - Continues to the next policy in the chain

### Policy Options

```ruby
policy :MyPolicy, ->() { ... },
  'Human-readable description',  # For logging
  cacheable: true,               # Cache results (default: true)
  single_match: false            # Only one subject can match
```

**`cacheable: true`** (default): Results are cached for the duration of the request, keyed by policy + arguments. Use for policies that don't depend on mutable state.

**`single_match: true`**: Optimization for policies for which there is only one matching Actor possible for a given Subject. For example in `AllowAuthors`, since a `Post` can have only one other, it's not worth a potentially expensive check on other combinations once you've found the winner. 

### Policy Combinators

Use `all()` to require multiple conditions:

```ruby
policy :AllowMemberToRemoveSelf, ->(subject, actor, direct_object) {
  all(
    P::AllowIfIncludesMember,
    P::AllowIfDirectObjectIsActor
  )
}
```

All sub-policies must return `:allow` for the combinator to return `:allow`. Any `:deny` results in `:deny`.

## Viewer Contexts

Viewer Contexts should be created by the router/controller layer of your application, you should generally
have one VC for the entire request lifecycle. The plugin provides several VC types for different use-cases.

Anonymous VCs are useful for logged out users, and can check that their access is properly constrained to things
that are meant to be fully public.

Omniscient VCs are most useful when your application needs to see an object that a user cannot for some reason.
Handle them with care. Login is the most salient example. 

All-Powerful VCs bypass all privacy checks and are used in situations where the system needs unfettered access
to models. In a production setting, your application should prohibit raw Database access outside of the privacy-aware
system, so these VCs give you an escape hatch for things like scripts while also keeping an audit trail. 

`omniscient` and `all_powerful` require a reason (symbol) for audit logging.

```ruby
# Standard viewer (most common)
current_vc = Sequel::Privacy::ViewerContext.for_actor(current_user)
users_groups = Group.for_vc(current_vc).where(creator: current_user).all

# API-specific (can be distinguished in policies)
vc = Sequel::Privacy::ViewerContext.for_api_actor(current_user)

# Anonymous viewer (logged-out users)
logged_out_vc = Sequel::Privacy::ViewerContext.anonymous
posts = Post.for_vc(logged_out_vc).where(published: true).all

# Omniscient VCs can read any object in the system, but are incapable of writes.
# Dispose of these ViewerContexts quickly. 
current_user = Sequel::Privacy::ViewerContext.omniscient(:login).then {|vc| User.for_vc(vc)[authenticated_user_id] }
current_vc = Sequel::Privacy::ViewerContext.for_actor(current_user)

# All-powerful ViewerContexts dangerously bypass all read and write checks.
admin_vc = Sequel::Privacy::ViewerContext.all_powerful(:admin_migration)
```

## Mutation Enforcement

When a viewer context is attached, mutations are automatically checked:

```ruby
member = Member.for_vc(vc).first

# Check :edit policy before saving existing records
member.name = "New Name"
member.save  # Raises Unauthorized if :edit denies

# Create new records with privacy enforcement
new_member = Member.for_vc(vc).create(name: "Test")
# or
new_member = Member.for_vc(vc).new(name: "Test")
new_member.save  # Raises Unauthorized if :create denies

# Check field-level policies when modifying protected fields
member.update(email: "new@example.com")  # Raises FieldUnauthorized if :view_email denies
```

### Association Privacy

For operations involving associations (like adding/removing members from a group), use the `association` block in the privacy DSL. This automatically wraps Sequel's association methods (`add_*`, `remove_*`, `remove_all_*`) with privacy checks.

```ruby
class Group < Sequel::Model
  plugin :privacy

  many_to_many :members, class: :User,
    join_table: :group_memberships,
    left_key: :group_id,
    right_key: :user_id

  privacy do
    can :view, P::AllowMembers
    can :edit, P::AllowAdmins

    association :members do
      can :add, P::AllowGroupAdmin, P::AllowSelfJoin
      can :remove, P::AllowGroupAdmin, P::AllowSelfRemove
      can :remove_all, P::AllowGroupAdmin
    end
  end
end
```

The `association` block supports three actions:
- `:add` - Wraps `add_*` method (e.g., `add_member`)
- `:remove` - Wraps `remove_*` method (e.g., `remove_member`)
- `:remove_all` - Wraps `remove_all_*` method (e.g., `remove_all_members`)

Association policies use 3-arity, receiving `(subject, actor, direct_object)`:
- `subject` - The model instance (e.g., the group)
- `actor` - The current user from the viewer context
- `direct_object` - The object being added/removed (e.g., the user being added to the group)

For `remove_all`, the direct object is `nil` since there's no specific target.

```ruby
# Allow users to add/remove themselves
policy :AllowSelfJoin, ->(_group, actor, target_user) {
  allow if actor.id == target_user.id
}, single_match: true

policy :AllowSelfRemove, ->(_group, actor, target_user) {
  allow if actor.id == target_user.id
}, single_match: true

# Allow group admins to add/remove anyone
policy :AllowGroupAdmin, ->(group, actor, _target_user) {
  allow if GroupAdmin.where(group_id: group.id, user_id: actor.id).exists?
}
```

Usage:

```ruby
group = Group.for_vc(vc).first

# User joins themselves (allowed by AllowSelfJoin)
group.add_member(current_user)

# Admin removes another user (allowed by AllowGroupAdmin)
group.remove_member(other_user)

# Admin removes all members
group.remove_all_members

# Non-admin trying to add someone else raises Unauthorized
group.add_member(other_user)  # Raises Sequel::Privacy::Unauthorized
```

Association privacy methods:
- Require a viewer context (raises `MissingViewerContext` if missing)
- Deny operations with `OmniscientVC` (read-only context cannot mutate)
- Work with both `one_to_many` and `many_to_many` associations

### Exception Types

- `Sequel::Privacy::Unauthorized` - Action denied at the record level
- `Sequel::Privacy::FieldUnauthorized` - Action denied at the field level
- `Sequel::Privacy::MissingViewerContext` - Attempted privacy-aware query without a viewer context

## Logging

Configure a logger to see policy evaluation:

```ruby
Sequel::Privacy.logger = Logger.new(STDOUT)
# or with SemanticLogger
Sequel::Privacy.logger = SemanticLogger['Privacy']
```

Log output shows:
- Policy evaluation results (ALLOW/DENY/PASS)
- Cache hits
- Single-match optimizations
- All-powerful/omniscient context bypasses

## Cache Management

Policy results are cached per-request to avoid redundant evaluation. Clear between requests:

```ruby
# In Rack middleware
class PrivacyCacheMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    Sequel::Privacy.clear_cache!
    @app.call(env)
  end
end
```

Or manually:

```ruby
Sequel::Privacy.cache.clear
Sequel::Privacy.single_matches.clear
```

## Actor Interface

Your user/member model must implement `Sequel::Privacy::IActor`:

```ruby
class Member < Sequel::Model
  include Sequel::Privacy::IActor

  def id
    self[:id]
  end
end
```

The interface requires:
- `id` - Returns the actor's unique identifier

You can add additional methods like `is_role?` for use in your policies, but they are not required by the interface.

## Policy Inheritance

Child classes inherit privacy policies from their parents:

```ruby
class User < Sequel::Model
  plugin :privacy

  privacy do
    can :view, P::AllowAdmins
  end
end

class Admin < User
  # Inherits :view policy
  privacy do
    can :edit, P::AllowSelf
  end
end
```

## Built-in Policies

- `Sequel::Privacy::BuiltInPolicies::AlwaysDeny` - Always denies (fail-secure default)
- `Sequel::Privacy::BuiltInPolicies::AlwaysAllow` - Always allows
- `Sequel::Privacy::BuiltInPolicies::PassAndLog` - Passes with a log message (useful for debugging)


## Type Safety (Sorbet)

The gem is mostly fully typed with Sorbet. Type definitions are provided for all public APIs. To ensure 
that Tapioca imports the required definitions, you may need to add this to your `sorbet/tapioca/require.rb`:

```ruby
require "sequel-privacy"
require "sequel/plugins/privacy"

# Force Tapioca to see the plugin modules by applying them to a dummy class
Class.new(Sequel::Model) do
  plugin :privacy
end
```

## AI Statement

The core of this project was written by me (arbales) over the course of 2025 for a platform that
manages mailing lists and member information for a social group. Claude assisted substantially with
extracting it into a Gem and wrote the tests in their entirety.

## License

MIT
