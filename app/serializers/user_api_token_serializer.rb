# frozen_string_literal: true

# Token utente CLI (Accounts::ApiToken, cyi_u_) nel canale CLI. MAI token_digest: il segreto vive solo
# nella risposta del create (reveal-once, aggiunto dal controller — non è un attributo del model).
class UserApiTokenSerializer < ApplicationSerializer
  attributes :id, :name, :token_prefix, :last_used_at, :expires_at, :revoked_at, :created_at
end
