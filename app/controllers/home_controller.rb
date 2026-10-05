# frozen_string_literal: true

# Home autenticata dell'area member. Risolve l'organizzazione di contesto se presente
# (account senza org → stato "nessuna organizzazione", senza redirect).
class HomeController < ApplicationController
  include OrganizationContext
  # CYRA-740 — la home non eredita da Member::BaseController ma disegna la stessa barra laterale e
  # legge gli stessi elenchi: le parti estratte le servono tutte e tre.
  include PermissionGates
  include VisibleResources
  include NavigationVisibility
  include GroupContext
  include Localizable
  include HomeSession

  layout "member"

  before_action :set_current_organization
  # CYRA-722 — la radice dell'area non eredita da Member::BaseController: il guard va montato anche
  # qui, o l'organizzazione sospesa resterebbe con la sua porta principale aperta.
  before_action :require_active_organization

  # B25 — same as Member::BaseController: the root of the area does not inherit from it, so the page
  # header would lose its toggle and its saved choice here.
  helper_method :page_header_compact?

  # CYRA-657 — UNA decisione per volta, la più vecchia. Prima qui c'erano quattro elenchi affiancati
  # e la prima cosa da fare, aprendo, era scegliere da dove cominciare: con quarantasette cose in
  # attesa quella scelta era già il lavoro. L'arretrato per intero resta sulla plancia, a un clic.
  #
  # Senza org → la view mostra lo stato "nessuna org", come prima.
  def index
    return unless current_organization

    @next = ::Home::NextDecision.call(
      account: Current.account,
      organization: current_organization,
      visible_projects: visible.projects,
      visible_tickets: visible.tickets,
      skipped: skipped_cards
    )
    # Lo stesso numero che la pagina delle decisioni mostra accanto al suo: quante vanno avanti da
    # sole senza chiedere niente a nessuno. Non si somma mai col primo.
    #
    # CYRA-665 — solo a chi risponde di almeno un progetto. `nil`, non zero: zero vuol dire «non ce
    # n'è nessuna», e a chi non governa nessun agente questo numero non deve comparire affatto. Il
    # predicato costa una query che si ferma alla prima riga; senza, ne costerebbe tre e
    # cinquecento oggetti buttati via per non mostrarli.
    @in_flight_total = in_flight_total
    # Esaurita la coda i salti non servono più: tenerli vorrebbe dire che domani, a coda ripopolata,
    # qualcosa resta nascosto senza che nessuno ricordi di averlo messo da parte.
    clear_skipped_cards if @next.card.nil? && !@next.all_hidden?
  end

  private

  def page_header_compact?
    Current.account&.page_header_compact? || false
  end

  def in_flight_total
    return nil unless ::Agents::Workflows::CtoProjects.any?(
      account: Current.account, organization: current_organization,
      visible_projects: visible.projects
    )

    ::Agents::Workflows::InFlight.autonomous_count(
      organization: current_organization, account: Current.account,
      visible_tickets: visible.tickets, visible_projects: visible.projects
    )
  end
end
