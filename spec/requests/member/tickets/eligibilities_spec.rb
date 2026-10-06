# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Eligibilities", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
  end
  let(:ticket) do
    create(:ticket, :agent_blocked, organization:, project:,
                    agent_eligibility_reason: "Sembra toccare la produzione.")
  end

  before { sign_in(owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "override umano" do
    it "consente agli agenti un ticket che il modello aveva bloccato" do
      patch member_ticket_eligibility_path(ticket), params: { eligibility: "allowed" }

      expect(response).to have_http_status(:found)
      expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "human")
      expect(ticket.agent_eligibility_decided_by).to eq(owner)
    end

    it "blocca un ticket che il modello aveva consentito" do
      allowed = create(:ticket, :agent_workable, organization:, project:)

      patch member_ticket_eligibility_path(allowed), params: { eligibility: "blocked" }

      expect(allowed.reload).to have_attributes(agent_eligibility: "blocked", agent_eligibility_source: "human")
    end

    it "salva la motivazione scritta da chi decide" do
      patch member_ticket_eligibility_path(ticket),
            params: { eligibility: "allowed", reason: "Ho controllato, tocca solo il frontend." }

      expect(ticket.reload.agent_eligibility_reason).to eq("Ho controllato, tocca solo il frontend.")
    end

    it "senza motivazione ne registra una che dice almeno chi ha deciso" do
      patch member_ticket_eligibility_path(ticket), params: { eligibility: "allowed" }

      expect(ticket.reload.agent_eligibility_reason).to include(owner.name)
    end

    it "rifiuta un valore non previsto senza toccare il ticket" do
      patch member_ticket_eligibility_path(ticket), params: { eligibility: "forse" }

      expect(flash[:alert]).to be_present
      expect(ticket.reload.agent_eligibility).to eq("blocked")
    end
  end

  describe "ritorno alla valutazione automatica" do
    before do
      Ticketing::SetAgentEligibility.call(ticket:, source: :human, eligibility: "allowed",
                                          reason: "sicuro", actor: owner)
    end

    it "riporta il ticket a da valutare e ne richiede subito una nuova" do
      expect do
        patch member_ticket_eligibility_path(ticket), params: { eligibility: "auto" }
      end.to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob).with(ticket_id: ticket.id)

      expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_source: "automatic")
    end
  end

  # CYRA-765 — non esiste più il ramo «servizio non collegato»: finché non c'è un verdetto la pagina
  # dice che il ticket è in attesa di essere esaminato, e quando il verdetto c'è parla quello.
  describe "la pagina del ticket senza verdetto" do
    let(:ticket) { create(:ticket, organization:, project:) }

    it "dice che il verdetto non è ancora arrivato" do
      get member_ticket_path(ticket)

      expect(response.body).to include(I18n.t("member.tickets.agent_eligibility.not_evaluated_yet"))
      expect(response.body).not_to include('data-test="member-ticket-agent-eligibility-not-connected"')
    end

    # CYRA-770 — il parere dell'AI si legge come un consiglio e non sposta la decisione: il badge
    # resta «da valutare», e accanto compare che cosa ne pensa l'AI.
    it "mostra il parere dell'AI senza spacciarlo per una decisione" do
      con_parere = create(:ticket, :agent_advice_allowed, organization:, project:)

      get member_ticket_path(con_parere)

      expect(response.body).to include('data-test="agent-eligibility-advice"')
      expect(response.body).to include(I18n.t("member.tickets.agent_eligibility.advice.allowed"))
      expect(response.body).to include(I18n.t("member.tickets.agent_eligibility.pending"))
      expect(response.body).not_to include(I18n.t("member.tickets.agent_eligibility.allowed"))
    end

    it "non mostra nessun riquadro del parere finché l'AI non si è espressa" do
      get member_ticket_path(ticket)

      expect(response.body).not_to include('data-test="agent-eligibility-advice"')
    end

    it "quando un verdetto c'è già, a parlare è il verdetto" do
      valutato = create(:ticket, :agent_blocked, organization:, project:,
                                 agent_eligibility_reason: "Tocca la produzione.")

      get member_ticket_path(valutato)

      expect(response.body).to include("Tocca la produzione.")
      expect(response.body).not_to include('data-test="member-ticket-agent-eligibility-not-connected"')
    end
  end

  describe "effetto sulla coda agenti" do
    it "un ticket sbloccato a mano torna disponibile per gli agenti" do
      create(:github_repository, project:)
      # In coda ci va solo un ticket con una lavorazione da fare: senza, lo sblocco non basta.
      create(:agent_workflow, ticket:, organization:)
      host = agent_host_seeing(project)
      expect(Agents::TicketQueues::Next.call(organization:, project_key: project.key, host:).value).to be_nil

      patch member_ticket_eligibility_path(ticket), params: { eligibility: "allowed" }

      expect(Agents::TicketQueues::Next.call(organization:, project_key: project.key, host:).value).to eq(ticket)
    end
  end

  # L'eleggibilità viveva in DUE posti nella pagina del ticket: il pannello dedicato e un campo dentro
  # Dettagli, con la stessa etichetta, lo stesso badge e la stessa motivazione. Ora sta solo nel
  # pannello. Queste spec tengono ferme le due cose che la deduplicazione poteva rompere: il target
  # del broadcast (l'id viveva nella copia rimossa) e i pulsanti di override (per-viewer, quindi
  # fuori dal target: se ci finissero dentro, il primo aggiornamento live li cancellerebbe).
  describe "pagina del ticket" do
    it "tiene il bersaglio degli aggiornamenti live dentro il pannello" do
      get member_ticket_path(ticket)

      panel = eligibility_panel
      expect(panel).to be_present
      expect(panel.at_css("[id='#{broadcast_target_id}']")).to be_present
    end

    it "mostra l'eleggibilità agenti una volta sola" do
      get member_ticket_path(ticket)

      expect(response.body.scan('data-test="member-ticket-agent-eligibility"').size).to eq(1)
      expect(response.body).not_to include('data-test="detail-agent-eligibility"')
    end

    it "lascia i pulsanti di override a chi gestisce il ticket, fuori dal bersaglio del broadcast" do
      get member_ticket_path(ticket)

      panel = eligibility_panel
      expect(panel.at_css('[data-test="agent-eligibility-allow"]')).to be_present
      expect(panel.text).to include("Sembra toccare la produzione.")
      # Dentro il bersaglio non ci devono stare: il broadcast è viewer-agnostico e li spazzerebbe via.
      expect(panel.at_css("[id='#{broadcast_target_id}'] [data-test='agent-eligibility-allow']")).to be_nil
    end

    it "states the verdict in the title and offers who works it as a two-way switch, never red" do
      get member_ticket_path(ticket)

      panel = eligibility_panel
      expect(panel.at_css("[data-test='agent-eligibility-title'] [data-test='agent-eligibility-badge']")).to be_present
      switch = panel.at_css("[data-test='agent-eligibility-switch']")
      expect(switch.at_css("[data-test='agent-eligibility-allow']")).to be_present
      expect(switch.at_css("[aria-pressed='true']").text).to include(I18n.t("member.tickets.agent_eligibility.switch.person"))
      expect(switch.to_html).not_to include("red-")
    end

    it "mostra il verdetto senza pulsanti a chi non gestisce il ticket" do
      member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
      create(:project_membership, account: member, project:)
      sign_in(member)

      get member_ticket_path(ticket)

      expect(response.body).to include('data-test="member-ticket-agent-eligibility"')
      expect(response.body).not_to include('data-test="agent-eligibility-allow"')
    end

    it "non ripete il codice del ticket dentro Dettagli" do
      get member_ticket_path(ticket)

      expect(response.body).to include('data-test="ticket-details"')
      expect(response.body).not_to include('data-test="detail-code"')
    end
  end

  describe "autorizzazione" do
    it "nega l'override a chi non può modificare il ticket" do
      member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
      create(:project_membership, account: member, project:)
      sign_in(member)

      patch member_ticket_eligibility_path(ticket), params: { eligibility: "allowed" }

      expect(response).to have_http_status(:forbidden).or have_http_status(:found)
      expect(ticket.reload.agent_eligibility).to eq("blocked")
    end

    # Anti-BOLA: un ticket di un'altra organizzazione non esiste, non è "vietato".
    it "risponde 404 su un ticket che l'utente non vede" do
      foreign = create(:ticket, organization: create(:organization))

      patch member_ticket_eligibility_path(foreign), params: { eligibility: "allowed" }

      expect(response).to have_http_status(:not_found)
    end
  end

  # Il gate non deve poter essere alzato da un submit del form di modifica: si cambia SOLO
  # dall'azione dedicata.
  describe "il form di modifica non può alzare il gate" do
    it "ignora agent_eligibility nei parametri del ticket" do
      patch member_ticket_path(ticket),
            params: { ticket: { title: ticket.title, description: "corpo aggiornato",
                                status_id: ticket.status_id, priority_id: ticket.priority_id,
                                agent_eligibility: "allowed" } }

      expect(ticket.reload.agent_eligibility).to eq("blocked")
    end
  end

  # Il target del broadcast di Ticketing::SetAgentEligibility: stesso id calcolato dal service.
  def broadcast_target_id
    "#{ActionView::RecordIdentifier.dom_id(ticket)}_agent_eligibility"
  end

  def eligibility_panel
    Nokogiri::HTML(response.body).at_css('[data-test="ticket-agent-eligibility-panel"]')
  end

  def agent_host_seeing(project)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}",
                                                    project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:).tap do |host|
      host.update!(last_heartbeat_at: Time.current, certified_at: Time.current,
                   repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
    end
  end
end
