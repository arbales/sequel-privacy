# frozen_string_literal: true

require 'roda'
require 'json'
require_relative 'models'

class App < Roda
  plugin :json
  plugin :json_parser
  plugin :all_verbs
  plugin :error_handler
  plugin :pass

  # In a production setting, you would probably not provide this level of detail,
  # just shown here for illustrative purposes.
  error do |e|
    case e
    when Sequel::Privacy::Unauthorized, Sequel::Privacy::FieldUnauthorized
      response.status = 403
      { error: e.message }
    else
      raise e
    end
  end

  route do |r|
    # Clear the privacy cache on every request. It's really intended you do this with
    # middleware, but shown here for simplicity.
    Sequel::Privacy.clear_cache!

    # This is a placeholder for however you choose to handle authentication and sessions
    # Since User is privacy-aware, you'll need to use an omniscient Viewer Context
    # in order to load it even for login.
    @current_user = r.params['session_user_id']&.to_i&.then { |id|
      User.for_vc(Sequel::Privacy::ViewerContext.omniscient(:for_login))[id]
    }

    # The user and the viewercontext are distinct, though typically the VC will be an actor vc that matches the users.
    # If there's not a current user, an anonymous VC is created so you can load objects that may be both privacy-aware *and*
    # offer a truly public view. You could imagine that Profiles on a social app can be seen by logged out users,
    # even if most of their fields and associations can only be viewed by logged-in users.
    @current_vc = @current_user ? Sequel::Privacy::ViewerContext.for_actor(@current_user) : Sequel::Privacy::ViewerContext.anonymous

    r.on 'users' do
      r.is do
        r.get do
          User.for_vc(@current_vc).all.collect do |u|
            {
              id: u.id,
              name: u.name,
              email: u.email
            }
          end
        end
      end

      r.on Integer do |id|
        user = User.for_vc(@current_vc)[id] or r.pass

        r.get do
          {
            id: user.id,
            name: user.name,
            email: user.email
          }
        end

        r.patch do
          user.update(r.params.slice('name', 'email'))
          {
            id: user.id,
            name: user.name
          }
        end
      end
    end

    r.on 'posts' do
      r.is do
        r.get do
          # This example application illustrates that post drafts you can't see are filtered by the privacy
          # framework, but it's an anti-pattern to try and fetch records you can't materialize, since
          # this results in records being processed by your application that users can never see.
          Post.for_vc(@current_vc).all.collect do |p|
            {
              id: p.id,
              title: p.title,
              published: p.published
            }
          end
        end
        r.post do
          post = Post.for_vc(@current_vc).create(
            title: r.params['title'],
            published: r.params['published'],
            author_id: @current_user&.id
          )
          {
            id: post.id,
            title: post.title
          }
        end
      end

      r.on Integer do |id|
        post = Post.for_vc(@current_vc)[id] or r.pass
        r.get do
          {
            id: post.id,
            title: post.title,
            published: post.published,
            author_id: post.author_id
          }
        end
        r.patch do
          post.update(r.params.slice('title', 'published'))
          {
            id: post.id,
            title: post.title
          }
        end
      end
    end

    r.on 'groups' do
      r.is do
        r.get do
          Group.for_vc(@current_vc).all.collect { |g| { id: g.id, name: g.name } }
        end
      end

      r.on Integer do |id|
        group = Group.for_vc(@current_vc)[id] or r.pass

        r.is do
          r.get do
            {
              id: group.id,
              name: group.name,
              members: group.members.map { |m| { id: m.id, name: m.name } }
            }
          end
        end

        # Demonstrates association-level privacy: add_member / remove_member
        # are wrapped by the privacy plugin and enforce the policies declared
        # in the Group model's `association :members` block.
        r.on 'members' do
          r.is do
            r.post do
              target = User.for_vc(@current_vc)[r.params['user_id'].to_i] or r.pass
              group.add_member(target)
              response.status = 201
              { added: target.id }
            end
          end

          r.on Integer do |user_id|
            r.delete do
              target = User.for_vc(@current_vc)[user_id] or r.pass
              group.remove_member(target)
              { removed: user_id }
            end
          end
        end
      end
    end
  end
end
