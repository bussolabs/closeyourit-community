# frozen_string_literal: true

module Chat
  # Intersezione delle visibilità di N account in un'organizzazione: i progetti che TUTTI vedono.
  # Base del gating dei DM (≥1 progetto comune) e del filtro delle risorse taggabili ("in comune").
  # USA Authorization::VisibleScope#projects (la relation: per owner/god = tutti i progetti dell'org),
  # NON visible_project_ids (che porta solo i link espliciti, vuoto per un owner non collegato).
  class CommonScope
    def initialize(accounts:, organization:)
      @accounts = Array(accounts).compact.uniq(&:id)
      @organization = organization
    end

    # Id dei progetti visibili a TUTTI gli account (intersezione). Vuoto se manca un account o se
    # l'intersezione è vuota. Un'unica passata batch (numero di query fisso, non per-account) via
    # Authorization::VisibleScope.project_ids_by_account — prima si istanziava una VisibleScope per
    # partecipante e le stesse pluck ripartivano per account (prosopite N+1).
    def project_ids
      return [] if @accounts.empty?

      @project_ids ||= begin
        by_account = Authorization::VisibleScope.project_ids_by_account(accounts: @accounts, organization: @organization)
        @accounts.map { |account| by_account[account.id] || Set.new }.reduce(:&).to_a
      end
    end

    # I progetti comuni come relation (per query a valle).
    def projects
      @organization.projects.where(id: project_ids)
    end

    def any?
      project_ids.any?
    end
  end
end
