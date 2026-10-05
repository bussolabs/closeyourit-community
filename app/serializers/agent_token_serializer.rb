# frozen_string_literal: true

# Token org dell'automator (canale CLI). MAI il token_digest: il segreto vive solo nella risposta del
# create (reveal-once, aggiunto dal controller — non è un attributo del model). Gemello di
# EnrollmentTokenSerializer (server) col prefisso cyi_a_.
class AgentTokenSerializer < ApplicationSerializer
  attributes :id, :name, :token_prefix, :last_used_at, :revoked_at, :created_at
end
