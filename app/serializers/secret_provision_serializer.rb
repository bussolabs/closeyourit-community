# frozen_string_literal: true

# Metadati operativi della consegna blind. Non serializza mai la variabile, il suo valore o il digest.
class SecretProvisionSerializer < ApplicationSerializer
  attributes :id, :status, :secret_name, :sync_github, :error_code, :error_message,
             :synced_at, :created_at, :updated_at,
             :source_project_id, :source_environment_id,
             :destination_project_id, :destination_environment_id
end
