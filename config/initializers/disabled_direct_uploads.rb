# frozen_string_literal: true

Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.prepend(DisabledDirectUploads)
end
