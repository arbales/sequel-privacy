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
```
