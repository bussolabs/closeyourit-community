# frozen_string_literal: true

module Member
  # Panoramica di un gruppo della sidebar (CYRA-139, rivista da CYRA-521): un solo controller
  # parametrizzato dal group_id di route (member_<id>_path). Non è più la destinazione di un cambio
  # d'area — quello non esiste più — ma la prima voce dentro il gruppo aperto: la pagina che dice se
  # c'è qualcosa da guardare. Le schede leggono gli stessi query object delle pagine di destinazione,
  # e le voci vengono dalle stesse definizioni gated della sidebar → zero duplicazione, permessi
  # sempre allineati. `Navigation::Group.find` è anti-tamper (id ignoto → Home).
  class OverviewsController < Member::BaseController
    def show
      @group = Navigation::Group.find(params[:group_id])
      # CYRA-334 — un'area con una destinazione sola non è un'area: è quella pagina. Portarci dritto
      # risparmia un clic che non insegna niente. È l'unica eccezione alla regola, ed è dichiarata.
      single = single_destination
      return redirect_to(single) if single

      # Ogni altra area apre coi propri numeri vivi, letti dagli scope visibili delle pagine di
      # destinazione: la landing non è più l'elenco dei link che si vedono già nel menu di fianco.
      @counts = ::Member::GroupOverview.new(
        group: @group, organization: current_organization,
        visible_projects: visible.projects, visible_tickets: visible.tickets,
        visible_ideas: visible.ideas,
        visible_seo_issues: visible.seo_issues, visible_seo_sites: visible.seo_sites
      ).counts
      area_matrix
    end

    private

    # CYRA-927/930 — an area landing is one table, a row per project and a column per signal, 12 rows
    # a page. Settings stays a list of pages: it has no signal to count per project.
    MATRICES = {
      "observability" => "Member::ObservabilityMatrix",
      "product" => "Member::ProductMatrix",
      "infrastructure" => "Member::InfrastructureMatrix",
      "alerts" => "Member::AlertsMatrix",
      "automation" => "Member::AutomationMatrix",
      "seo" => "Member::SeoMatrix"
    }.freeze

    def area_matrix
      klass = MATRICES[@group.id]&.constantize or return

      @matrix = klass.new(visible_projects: visible.projects, account: Current.account,
                          organization: current_organization, can: ->(key) { can?(key) },
                          visible_paths: helpers.group_leaf_items(@group).map(&:path))
      @matrix_pagination = paginate(@matrix.listed_scope(query: search_q, problems: params[:health] == "problems",
                                                         sort: params[:sort]))
    end

    # Le voci visibili del gruppo sono quelle della sidebar: se ne resta una sola, la panoramica non ha
    # niente da riassumere che quella pagina non dica già meglio.
    def single_destination
      items = helpers.group_leaf_items(@group)
      items.first&.path if items.size == 1
    end
  end
end
