# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # Interface for actors used in viewer contexts (typically User/Member).
    module IActor
      extend T::Sig
      extend T::Helpers
      interface!

      sig { abstract.returns(Integer) }
      def id; end
    end
  end
end
