# frozen_string_literal: true

require "rails_helper"

# ── CYRA-627 ──────────────────────────────────────────────────────────────────────────────────────
#
# Accanto a ogni criterio di accettazione c'era una spunta VERDE, disegnata sempre, su ogni ticket,
# anche quando nessuno aveva verificato niente e non esisteva nessun modo per verificarlo: un
# semaforo verde attaccato a un filo staccato. E per sapere quale codice fosse uscito bisognava
# uscire dal ticket, o fidarsi di una frase scritta da chi aveva lavorato.
RSpec.describe "Member::Tickets — verbale di consegna", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
  let(:ticket) { create(:ticket, organization: org, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:sha) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def candidato!(tratto = :verified_passing, checks: 3)
    riga = create(:agent_delivery_candidate, tratto, workflow:, organization: org,
                                             repository:, repository_full_name: repository.full_name,
                                             number: 7, head_sha: sha, base_ref: "main",
                                             checks_count: checks)
    workflow.update!(review_candidate: riga)
    riga
  end

  # Nessuna delle quattro icone deve più affermare uno stato: non c'è nessuno stato da affermare.
  it "i criteri di accettazione non portano più una spunta verde" do
    create(:ticketing_condition, ticket:, text: "Gli spec passano")

    get member_ticket_path(ticket)

    riga = Nokogiri::HTML(response.body).at_css('[data-test="ticket-conditions"]')
    expect(riga).to be_present
    expect(riga.to_html).not_to include("fa-square-check")
    expect(riga.to_html).not_to include("text-emerald")
  end

  describe "il verbale" do
    it "dice deposito, proposta, codice per intero, ramo e come sono andati i controlli" do
      candidato!

      get member_ticket_path(ticket, tab: "report")

      verbale = Nokogiri::HTML(response.body).at_css('[data-test="ticket-delivery-evidence"]')
      expect(verbale).to be_present
      expect(verbale.text).to include("bussolabs/closeyourit-rails")
      expect(verbale.text).to include("#7")
      # Per intero: un abbreviato non identifica niente.
      expect(verbale.at_css('[data-test="ticket-evidence-sha"]').text).to eq(sha)
      expect(verbale.text).to include("main")
    end

    # Zero controlli falliti non vuol dire verde: vuol dire che nessuno ha guardato. Le due cose si
    # scrivono con parole diverse, o il verbale racconta la stessa bugia della spunta.
    it "«nessun controllo» non si racconta come un esito positivo" do
      candidato!(:verified_none_configured, checks: 0)

      get member_ticket_path(ticket, tab: "report")

      riga = Nokogiri::HTML(response.body).at_css('[data-test="ticket-evidence-checks"]')
      expect(riga.text).to include(I18n.t("member.tickets.evidence.checks_none", count: 0, locale: I18n.locale))
      expect(riga.text).not_to include(I18n.t("member.tickets.evidence.checks_passing", count: 0, locale: I18n.locale))
    end

    # Il buco si dichiara: uno spazio vuoto sembrerebbe normale, e chi legge non saprebbe di stare
    # guardando un lavoro accettato sulla parola.
    it "senza prova collegata lo dice, invece di lasciare uno spazio vuoto" do
      get member_ticket_path(ticket, tab: "report")

      verbale = Nokogiri::HTML(response.body).at_css('[data-test="ticket-delivery-evidence"]')
      expect(verbale).to be_present
      expect(verbale.at_css('[data-test="ticket-evidence-candidate-none"]')).to be_present
      expect(verbale.at_css('[data-test="ticket-evidence-release-none"]')).to be_present
    end

    it "quando il rilascio è stato visto in piedi porta il numero di versione" do
      candidato!
      workflow.probes.create!(kind: "deploy_smoke", bound_at: 2.hours.ago, closed_at: 1.hour.ago,
                              expected: { "version" => "v0.30.0", "sha" => sha, "repo" => repository.full_name })

      get member_ticket_path(ticket, tab: "report")

      riga = Nokogiri::HTML(response.body).at_css('[data-test="ticket-evidence-release-version"]')
      expect(riga.text).to include("v0.30.0")
    end

    # Il verbale è un verbale: non ha pulsanti e non fa avanzare niente.
    it "non porta nessun pulsante" do
      candidato!

      get member_ticket_path(ticket, tab: "report")

      verbale = Nokogiri::HTML(response.body).at_css('[data-test="ticket-delivery-evidence"]')
      expect(verbale.css("button, form")).to be_empty
    end

    # Niente chiamate a GitHub mentre si disegna: la pagina non deve rallentare se GitHub è lento, e
    # il verbale non deve cambiare sotto gli occhi di chi legge.
    it "non chiede niente a GitHub mentre disegna" do
      candidato!
      allow(Github::Client).to receive(:new).and_raise("non doveva chiamare GitHub")

      get member_ticket_path(ticket, tab: "report")

      expect(response).to have_http_status(:ok)
    end
  end
end
