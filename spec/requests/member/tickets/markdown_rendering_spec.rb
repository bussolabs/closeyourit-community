# frozen_string_literal: true

require "rails_helper"

# CYRA-261 — il markdown si legge RESO, non coi suoi simboli. Il testo di queste schede lo scrivono
# agenti e riga di comando, che scrivono in markdown per natura: la scheda Automazione era la peggiore
# (piano e passi sono i testi più lunghi dell'app). Qui si inchioda il contratto sulle pagine vere,
# non solo sul componente: che il markdown arrivi reso, che il testo semplice non cambi, e che l'HTML
# di chi scrive resti testo.
RSpec.describe "Member ticket markdown rendering", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) { create(:account) }

  before do
    create(:membership, :owner, organization:, account: cto)
    create(:project_membership, project:, account: cto)
    organization.update!(cto:)
    post login_path, params: { email: cto.email, password: "Secret123!" }
  end

  describe "la scheda del ticket" do
    it "rende la descrizione scritta in markdown" do
      ticket.update!(description: "## Contesto\n\n- primo punto\n- secondo punto\n\nCon **enfasi**.")

      get member_ticket_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<h2>Contesto</h2>")
      expect(response.body).to include("<li>primo punto</li>")
      expect(response.body).to include("<strong>enfasi</strong>")
      expect(response.body).not_to include("## Contesto")
    end

    # Chi scrive senza markdown non deve accorgersi di niente: gli a capo singoli restano a capo.
    it "tiene gli a capo del testo scritto senza formattazione" do
      ticket.update!(description: "prima riga\nseconda riga")

      get member_ticket_path(ticket)

      expect(response.body).to include("prima riga<br>\nseconda riga")
    end

    it "rende gli scenari e le condizioni in linea, senza mandarli a capo sotto l'etichetta" do
      scenario = ticket.scenarios.create!(title: "Caso base", step_given: "un ticket con `codice`",
                                          step_when: "premo **Crea**", step_then: "vedo l'esito", position: 1)
      ticket.conditions.create!(text: "La spec `automation_tab` è verde", position: 1)

      get member_ticket_path(ticket)

      expect(response.body).to include("<code>codice</code>")
      expect(response.body).to include("<strong>Crea</strong>")
      expect(response.body).to include("<code>automation_tab</code>")
      # inline = niente <p> attorno allo step, o la griglia etichetta/valore si spezza.
      expect(response.body).not_to include("<p>premo <strong>Crea</strong></p>")
      expect(scenario.reload.step_when).to eq("premo **Crea**")
    end

    it "lascia l'HTML di chi scrive come testo visibile, mai come markup" do
      ticket.update!(description: "usa <div> per il layout <script>alert(1)</script>")

      get member_ticket_path(ticket)

      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(response.body).to include("&lt;div&gt;")
    end
  end

  describe "i commenti" do
    it "rende il markdown del commento (li scrivono anche gli agenti)" do
      create(:ticket_comment, organization:, ticket:, author: cto,
                              body: "Fatto:\n\n- [x] analisi\n- [ ] rilascio")

      get member_ticket_path(ticket, tab: "discussion")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<li><input type=\"checkbox\"")
      expect(response.body).not_to include("- [x] analisi")
    end
  end

  describe "la scheda Automazione" do
    let(:attempt) { create(:agent_attempt, organization:, workflow:) }

    it "rende il piano: analisi, scenari, condizioni e note" do
      workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current, ticket_snapshot_digest: "snapshot")
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot",
                           technical_analysis: "### Passi\n\n1. toccare `app/models/foo.rb`\n2. aggiornare la spec",
                           scenarios: [ { "given" => "un piano con `codice`", "when" => "apro la scheda",
                                          "then" => "leggo formattato", "expected" => "nessun simbolo" } ],
                           definition_of_done: [ "La spec `foo_spec` passa" ],
                           notes: [ "Attenzione al **tetto** di revisione" ])

      get member_ticket_path(ticket, tab: "automation")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<h3>Passi</h3>")
      expect(response.body).to include("<code>app/models/foo.rb</code>")
      expect(response.body).to include("<code>codice</code>")
      expect(response.body).to include("<code>foo_spec</code>")
      expect(response.body).to include("<strong>tetto</strong>")
      expect(response.body).not_to include("### Passi")
    end

    it "rende le considerazioni del passo e il verdetto della revisione" do
      create(:agent_attempt, organization:, workflow:, phase: "planner", status: :review_failed,
                             started_at: 1.minute.ago, finished_at: 30.seconds.ago,
                             result: { "technical_analysis" => "Serve **una** migrazione" },
                             review: { "status" => "changes_requested", "summary" => "Manca la prova su `bin/ci`" })

      get member_ticket_path(ticket, tab: "automation")

      expect(response.body).to include("Serve <strong>una</strong> migrazione")
      expect(response.body).to include("<code>bin/ci</code>")
    end

    # Le domande non possono contenere codice o percorsi (devono restare semplici), quindi qui il
    # markdown che conta è l'enfasi; la risposta invece è testo libero di una persona e ci finisce di
    # tutto. CYRA-782 — si leggono nella scheda Domande, non più in quella dell'automazione.
    it "rende le domande e la risposta nella scheda Domande" do
      autore = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
      question = Ticketing::Question.create!(ticket:, author: autore, origin: :agent,
                                             body: "Vale anche per la **riga di comando**?")
      Ticketing::Questions::Answer.call(question:, author: autore,
                                        body: "Sì, **anche** da `cyi tickets update`")

      get member_ticket_path(ticket, tab: "questions")

      expect(response.body).to include("<strong>riga di comando</strong>")
      expect(response.body).to include("<code>cyi tickets update</code>")
      expect(response.body).to include("<strong>anche</strong>")
    end
  end
end
