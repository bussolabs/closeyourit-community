# frozen_string_literal: true

# Base dei service object: entry point unico `.call` (rules/rails/services.md).
class ApplicationService
  def self.call(...) = new(...).call
end
