# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # Interface that actors (typically User/Member models) must implement
    # to be used with the privacy system.
    module IActor
      extend T::Sig
      extend T::Helpers
      interface!

      sig { abstract.returns(Integer) }
      def id; end

      sig { abstract.params(roles: Symbol).returns(T::Boolean) }
      def is_role?(*roles); end
    end
  end
end
