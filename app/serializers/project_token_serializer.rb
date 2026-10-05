# frozen_string_literal: true

# MAI esporre token_digest o il segreto (rules/rails/api.md). public_key è per design non segreta.
class ProjectTokenSerializer < ApplicationSerializer
  attributes :id, :name, :environment_id, :token_prefix, :public_key, :scopes,
             :last_used_at, :revoked_at, :expires_at, :created_at
end
