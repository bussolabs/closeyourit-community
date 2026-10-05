# frozen_string_literal: true

module Secrets
  # Vault PERSONALE per-utente (gemello di Secrets::, che è per-progetto): scoped a [account, organization],
  # struttura FLAT (niente environment), nessun sync GitHub, nessun RBAC (ownership come Todos::List).
  module Personal
    def self.table_name_prefix = "secrets_personal_"
  end
end
