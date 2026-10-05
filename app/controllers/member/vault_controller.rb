# frozen_string_literal: true

module Member
  # Landing dello space "Vault" (CYRA-133): overview con le vie d'accesso ai secret unificati —
  # Personale / Organizzazione / Progetto, ciascuno Variabili + File. Nessuna aggregazione nuova
  # (YAGNI): solo card verso pagine ESISTENTI (+ i nuovi file personali). La visibilità delle card org
  # è gated come in sidebar (can? shared_secrets.manage / shared_secret_files.manage); il personale è
  # ungated (ownership); il progetto passa dal picker (member_vault_projects).
  class VaultController < Member::BaseController
    permission_not_required "Ingresso della cassaforte: soltanto collegamenti a pagine che applicano ognuna il " \
                            "proprio permesso."

    def overview
      projects = visible.projects.to_a
      @overview = Member::VaultOverview.new(organization: Current.organization, account: Current.account)
      # CYRA-930 — what each project keeps and what is wrong with it, a row per project.
      @matrix = Member::VaultMatrix.new(visible_projects: visible.projects, account: Current.account,
                                        organization: Current.organization)
      @matrix_pagination = paginate(@matrix.projects_scope)
      # CYRA-430 — e la quarta: quali collegamenti automatici sono accesi e su quanti progetti.
      @integrations = ::Secrets::Integrations.new(organization: Current.organization,
                                                  visible_project_ids: projects.map(&:id))
      # F148 — the commands of "Use this secret" filled with a project and an environment of choice.
      @usage_projects = projects.sort_by { |project| project.name.downcase }
      @usage_project = projects.find { |project| project.key == params[:usage_project] }
      @usage_environments = @usage_project ? @usage_project.environments.ordered.map(&:code) : []
      @usage_environment = @usage_environments.find { |code| code == params[:usage_environment] } ||
                           @usage_environments.find { |code| code == "production" } || @usage_environments.first
    end
  end
end
