# Example

```bash
bundle install
ruby seed.rb
bundle exec puma
```

## Test

```bash
# Bob sees his own email, not Carol's
curl "localhost:9292/users?session_user_id=2"

# Bob sees his draft, Carol doesn't
curl "localhost:9292/posts?session_user_id=2"
curl "localhost:9292/posts?session_user_id=3"

# Carol can't edit Bob's post
curl -X PATCH -H "Content-Type: application/json" \
  -d '{"title":"Hacked"}' "localhost:9292/posts/1?session_user_id=3"

# Anonymous user can only see published posts
curl "localhost:9292/posts"

# Carol joins the Book Club herself (AllowSelfJoin)
curl -X POST -d "user_id=3" "localhost:9292/groups/1/members?session_user_id=3"

# Carol can't add Alice (not group admin, not self)
curl -X POST -d "user_id=1" "localhost:9292/groups/1/members?session_user_id=3"

# Alice (admin) can add anyone
curl -X POST -d "user_id=1" "localhost:9292/groups/1/members?session_user_id=1"

# View the group with its members
curl "localhost:9292/groups/1?session_user_id=2"
```
