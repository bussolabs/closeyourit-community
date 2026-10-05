# frozen_string_literal: true

module Telegram
  # Visibilità progetti per i comandi Telegram. Un chat_id → un account, ma l'account può stare in
  # più org: le org candidate sono TUTTE le sue (o tutte quelle esistenti, se god). Dentro ogni org
  # la visibilità dei progetti resta quella canonica (Authorization::VisibleScope: owner/god tutto,
  # gli altri solo gli assegnati). Fonte unica riusata da ResolveProject/ResolveTicket/List*.
  module VisibleProjects
    private

    # Org in cui cercare i progetti dell'account. god non ha membership in prod → tutte le org.
    #
    # CYRA-722 — mai quelle sospese: il bot è un'altra porta della stessa organizzazione, e da qui
    # passano elenco progetti, apertura ticket, commenti e letture. Il filtro sta in questo punto
    # solo, che è la fonte unica dei comandi: metterlo nei comandi vorrebbe dire ricordarsene ogni
    # volta che se ne aggiunge uno. Il god resta fuori dal filtro, come nell'area web e nelle API.
    def candidate_organizations(account)
      account.god? ? Organizations::Organization.all : account.organizations.active
    end

    def project_scope(account, organization)
      Authorization::VisibleScope.new(account: account, organization: organization).projects
    end

    # Tutti i progetti visibili dell'account cross-org, ordinati per key (per gli elenchi).
    def all_visible_projects(account)
      candidate_organizations(account).flat_map { |org| project_scope(account, org).to_a }
                                      .uniq(&:id).sort_by(&:key)
    end
  end
end
