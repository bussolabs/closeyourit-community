class Current < ActiveSupport::CurrentAttributes
  # :session = sessione di autenticazione corrente (Accounts::Session).
  # :true_account = chi è loggato davvero (il god, anche durante l'impersonation).
  # :account = account che l'app "vede" (l'impersonato se attivo, altrimenti true_account).
  # :organization = organizzazione di contesto dell'area member.
  # :project, :api_token = contesto del path API a token (senza sessione): il token pinna
  #   organization+project, account resta nil. Così tutto il codice org-scoped funziona invariato.
  attribute :session, :true_account, :account, :organization, :project, :api_token, :server_host, :agent_host, :cluster
  # :ai_configuration = Ai::Configuration snapshot, read once per request or job (CYRA-916).
  attribute :ai_configuration
end
