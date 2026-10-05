# frozen_string_literal: true

# Base dei serializer JSON (Alba). I serializer concreti ereditano da qui (rules/rails/api.md).
class ApplicationSerializer
  include Alba::Resource
end
