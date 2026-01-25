# typed: strict
# frozen_string_literal: true

module Sequel
  module Privacy
    # Raised when a viewer is not authorized to perform an action (view, edit, create)
    class Unauthorized < StandardError; end

    # Raised when a viewer is not authorized to access or modify a specific field
    class FieldUnauthorized < StandardError; end

    # Raised when a policy returns an invalid outcome
    class InvalidPolicyOutcomeError < StandardError; end

    # Raised when an invalid viewer context is used
    class InvalidViewerContextError < StandardError; end

    class MissingViewerContext < StandardError; end
  end
end
