# frozen_string_literal: true

# Result pattern per i service object (rules/error-handling.md).
# Ok porta il valore, Err porta un AppError.
Result = Data.define(:success, :value, :error) do
  def self.ok(value = nil) = new(success: true, value: value, error: nil)
  def self.err(error) = new(success: false, value: nil, error: error)

  def ok? = success
  def err? = !success
end
