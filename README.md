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

  # Re-export built-in policies
  AlwaysDeny = Sequel::Privacy::BuiltInPolicies::AlwaysDeny
  AlwaysAllow = Sequel::Privacy::BuiltInPolicies::AlwaysAllow
  PassAndLog = Sequel::Privacy::BuiltInPolicies::PassAndLog

  # Define application-specific policies
  policy :AllowAdmins, ->(actor) {
    allow if actor.is_role?(:admin)
  }, 'Allow admin users', cacheable: true

  policy :AllowSelf, ->(subject, actor) {
    allow if subject == actor
  }, 'Allow if subject is the actor', single_match: true

  policy :AllowMembers, ->(actor) {
    allow if actor.is_role?(:member)
  }, cacheable: true
end
```

### 2. Add Privacy to Your Models

```ruby
class Member < Sequel::Model
  plugin :privacy

  # Define who can view this model
  policies :view, P::AllowSelf, P::AllowMembers, P::AlwaysDeny

  # Define who can view specific fields
  policies :view_email, P::AllowMembers, P::AlwaysDeny
  policies :view_phone, P::AllowSelf, P::AllowAdmins, P::AlwaysDeny

  # Define who can edit
  policies :edit, P::AllowSelf, P::AllowAdmins, P::AlwaysDeny

  # Define who can create
  policies :create, P::AllowAdmins, P::AlwaysDeny

  # Protect sensitive fields
  protect_field :email
  protect_field :phone, policy: :view_phone
end
```

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

policy :AllowAdmins, ->(actor) {
  allow if actor.is_role?(:admin)
}

policy :AllowOwner, ->(subject, actor) {
  allow if subject.owner_id == actor.id
}

policy :AllowIfInvited, ->(subject, actor, direct_object) {
  allow if direct_object&.inviter_id == actor.id
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
  single_match: false            # Only one subject can match (optimization)
```

**`cacheable: true`** (default): Results are cached for the duration of the request, keyed by policy + arguments. Use for policies that don't depend on mutable state.

**`single_match: true`**: Optimization for policies like "user can only see their own record." Once a match is found for an actor, the policy automatically returns `:pass` for other subjects.

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
have one VC for the entire request lifecycle. The plugin provides three builtin VC types for different use-cases.

All-Powerful VCs bypass all privacy checks and are used in situations where the system needs unfettered access
to models. In a production setting, your application should prohibit raw Database access outside of the privacy-aware
system, so these VCs give you an escape hatch for things like scripts while also keeping an audit trail. 

```ruby
# Standard viewer (most common)
vc = Sequel::Privacy::ViewerContext.for_actor(current_user)

# API-specific (can be distinguished in policies)
vc = Sequel::Privacy::ViewerContext.for_api_actor(current_user)

# All-powerful (bypasses all checks - use sparingly!)
vc = Sequel::Privacy::ViewerContext.all_powerful("admin migration script")
```

The all-powerful context logs its creation for audit purposes.

## Mutation Enforcement

When a viewer context is attached, mutations are automatically checked:

```ruby
member = Member.for_vc(vc).first

# Check :edit policy before saving existing records
member.name = "New Name"
member.save  # Raises Unauthorized if :edit denies

# Check :create policy before saving new records
new_member = Member.new(name: "Test").for_vc(vc)
new_member.save  # Raises Unauthorized if :create denies

# Check field-level policies when modifying protected fields
member.update(email: "new@example.com")  # Raises FieldUnauthorized if :view_email denies
```

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
- All-powerful context bypasses

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

  def is_role?(*roles)
    roles.include?(permission_level.downcase.to_sym)
  end
end
```

The interface requires:
- `id` - Returns the actor's unique identifier
- `is_role?(*roles)` - Returns true if the actor has any of the given roles

## Policy Inheritance

Child classes inherit privacy policies from their parents:

```ruby
class User < Sequel::Model
  plugin :privacy
  policies :view, P::AllowAdmins, P::AlwaysDeny
end

class Admin < User
  # Inherits :view policy
  policies :edit, P::AllowSelf, P::AlwaysDeny
end
```

## Built-in Policies

- `Sequel::Privacy::BuiltInPolicies::AlwaysDeny` - Always denies (fail-secure default)
- `Sequel::Privacy::BuiltInPolicies::AlwaysAllow` - Always allows
- `Sequel::Privacy::BuiltInPolicies::PassAndLog` - Passes with a log message (useful for debugging)

## Best Practices

1. **Always end policy chains with `AlwaysDeny`** - Fail-secure by default
2. **Use `cacheable: true`** for policies that don't depend on request-specific state
3. **Use `single_match: true`** for "allow self" type policies to optimize batch queries
4. **Clear cache between requests** to prevent stale results
5. **Log policy evaluation** in development to understand privacy behavior
6. **Define policies explicitly** - Undefined actions return `false` by default

## Type Safety (Sorbet)

The gem is fully typed with Sorbet (`typed: strict`). Type definitions are provided for all public APIs.

## License

MIT
