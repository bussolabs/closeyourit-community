# frozen_string_literal: true

require "rails_helper"

# ── CYRA-623 ──────────────────────────────────────────────────────────────────────────────────────
#
# Quello che si vede: sulla scheda, al posto di «in coda», il codice del ticket che sta trattenendo;
# nelle liste, lo stesso segno «bloccato» che la bacheca mostra già.
RSpec.describe "Member::Tickets — prerequisiti in vista", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:aperto) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:ticket) { create(:ticket, :agent_workable, organization: org, project:, status: aperto, with_agent_workflow: true) }
  let(:blocker) { create(:ticket, organization: org, project:, status: aperto) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project:)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # La riga «perché si è fermata», non la pagina intera: il codice del prerequisito la pagina lo
  # stampa comunque nel riquadro dei prerequisiti, e cercarlo lì dentro farebbe passare la prova anche
  # senza aver toccato niente.
  # La pagina si legge nella lingua di chi guarda: la frase si prende dalla stessa chiave che stampa la
  # vista, non copiata a mano — una copia in italiano su una pagina in inglese passerebbe da sola.
  def frase_in_coda = I18n.t("member.tickets.automation.summary.stopped.queued", locale: I18n.locale)

  def riga_perche_si_e_fermata
    Nokogiri::HTML(response.body).at_css('[data-test="automation-summary"]')&.text.to_s.squish
  end

  describe "la riga «perché si è fermata»" do
    before { pronta_per!(ticket.agent_workflow, "autopilot") }

    it "nomina il prerequisito invece di promettere una macchina libera" do
      create(:ticket_dependency, ticket:, blocker:)
      sign_in(owner)

      get member_ticket_path(ticket, tab: "automation")

      expect(riga_perche_si_e_fermata).to include(blocker.code)
      expect(riga_perche_si_e_fermata).not_to include(frase_in_coda)
    end

    # Un prerequisito in un progetto che chi guarda non può vedere resta un fatto senza codice: il
    # codice non deve comparire in NESSUN punto della risposta, nemmeno nel riquadro dei prerequisiti.
    it "un prerequisito fuori scope non fa trapelare il suo codice" do
      nascosto = create(:ticket, organization: org, project: create(:project, organization: org), status: aperto)
      create(:ticket_dependency, ticket:, blocker: nascosto)
      sign_in(member)

      get member_ticket_path(ticket, tab: "automation")

      # Il codice non deve comparire in NESSUN punto della risposta, nemmeno nel riquadro dei
      # prerequisiti: è un ticket di un progetto che chi guarda non può vedere.
      expect(response.body).not_to include(nascosto.code)
      expect(riga_perche_si_e_fermata)
        .to include(I18n.t("member.tickets.automation.summary.stopped.dependencies_anonymous").squish)
    end

    # «Trattenuta» vuol dire che la coda la sta saltando. Un lavoro che la macchina ha già preso in
    # mano non lo sta aspettando nessuno: dirlo trattenuto sarebbe falso quanto la frase di prima.
    it "su un lavoro già in mano alla macchina la riga non dice «trattenuta»" do
      create(:ticket_dependency, ticket:, blocker:)
      ticket.agent_workflow.update!(autopilot_started_at: Time.current)
      sign_in(owner)

      get member_ticket_path(ticket, tab: "automation")

      expect(ticket.agent_workflow.reload.ready_execution_phase).to be_nil
      expect(riga_perche_si_e_fermata).not_to include(blocker.code)
    end

    it "senza prerequisiti la riga è quella di sempre" do
      sign_in(owner)

      get member_ticket_path(ticket, tab: "automation")

      expect(riga_perche_si_e_fermata).to include(frase_in_coda)
    end

    # Aprire la scheda non può costare di più perché i prerequisiti sono tanti: l'elenco esce da
    # un'unica interrogazione, limitata.
    it "costa lo stesso con un prerequisito e con dieci" do
      create(:ticket_dependency, ticket:, blocker:)
      sign_in(owner)
      get member_ticket_path(ticket, tab: "automation")
      con_uno = captured_sql { get member_ticket_path(ticket, tab: "automation") }.size

      allow_n_plus_one do
        9.times { create(:ticket_dependency, ticket:, blocker: create(:ticket, organization: org, project:, status: aperto)) }
      end
      con_dieci = captured_sql { get member_ticket_path(ticket, tab: "automation") }.size

      expect(con_dieci).to eq(con_uno)
    end
  end

  describe "il segno «bloccato» nelle liste" do
    it "compare sulla riga del ticket trattenuto, e non su quella libera" do
      create(:ticket_dependency, ticket:, blocker:)
      libero = create(:ticket, organization: org, project:, status: aperto)
      sign_in(owner)

      get list_member_tickets_path

      expect(response.body).to include("ticket-list-blocked-#{ticket.id}")
      expect(response.body).not_to include("ticket-list-blocked-#{libero.id}")
    end

    # Con OGNI riga bloccata il conto non deve crescere: il segno esce da un'unica interrogazione
    # aggregata, mai da un controllo per riga. Il confronto è a PARITÀ DI RIGHE — dieci righe pulite
    # contro dieci righe tutte bloccate — perché altrimenti si misurerebbe il costo di avere più
    # ticket, che non è quello che questo lavoro tocca.
    it "con ogni riga bloccata il costo è lo stesso di righe tutte pulite" do
      pulite = allow_n_plus_one do
        10.times.map { create(:ticket, organization: org, project:, status: aperto) }
      end
      sign_in(owner)
      get list_member_tickets_path
      tutte_pulite = captured_sql { get list_member_tickets_path }.size

      allow_n_plus_one do
        pulite.each do |riga|
          create(:ticket_dependency, ticket: riga,
                                     blocker: create(:ticket, organization: org, project:, status: aperto))
        end
      end
      tutte_bloccate = captured_sql { get list_member_tickets_path }.size

      expect(response).to have_http_status(:ok)
      expect(tutte_bloccate).to eq(tutte_pulite)
    end
  end
end
