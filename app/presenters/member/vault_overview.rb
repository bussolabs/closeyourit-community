# frozen_string_literal: true

module Member
  # The Vault landing header: the secrets that belong to no project (CYRA-135, CYRA-930). The
  # project ones are counted row by row in Member::VaultMatrix.
  class VaultOverview
    def initialize(organization:, account:)
      @organization = organization
      @account = account
    end

    # Conteggi per livello (CYRA-413): "quanti sono" sotto ogni tipo della landing. Variabili + file.
    # Personale = i soli segreti dell'account nell'org (ownership). Gli asset archiviati non contano.
    def personal_secrets_count
      Secrets::Personal::Variable.where(account_id: @account.id, organization_id: @organization.id).count +
        Secrets::Personal::Asset.where(account_id: @account.id, organization_id: @organization.id).active.count
    end

    # Organizzazione = segreti org-level (project_id nil per gli asset), delegabili ai progetti.
    def organization_secrets_count
      @organization.shared_secret_variables.count +
        @organization.secret_assets.where(project_id: nil).active.count
    end
  end
end
