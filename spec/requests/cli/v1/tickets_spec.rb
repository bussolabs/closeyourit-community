# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto (project_membership) ma senza permessi di gestione ticket → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  it "index → 200 con i ticket del progetto e meta" do
    ticket = create(:ticket, project:, organization:)
    get "/cli/v1/projects/#{project.id}/tickets", headers: headers

    expect(response).to have_http_status(:ok)
    ids = response.parsed_body["data"].map { |t| t["id"] }
    expect(ids).to include(ticket.id)
    expect(response.parsed_body["meta"]).to include("total")
  end

  describe "GET index filters for the caller's own work" do
    let(:done_status) { create(:ticket_status, organization:, category: :done) }

    def listed_ids(params)
      get "/cli/v1/projects/#{project.id}/tickets", params:, headers: headers
      response.parsed_body["data"].map { |t| t["id"] }
    end

    it "assignee=me keeps only the tickets assigned to the token's account" do
      mine = create(:ticket, project:, organization:, assignee: account)
      unassigned = create(:ticket, project:, organization:)

      ids = listed_ids(assignee: "me")

      expect(ids).to include(mine.id)
      expect(ids).not_to include(unassigned.id)
    end

    it "open=true leaves out the tickets whose status is done" do
      open_ticket = create(:ticket, project:, organization:)
      closed = create(:ticket, project:, organization:, status: done_status)

      ids = listed_ids(open: "true")

      expect(ids).to include(open_ticket.id)
      expect(ids).not_to include(closed.id)
    end

    it "rejects an assignee other than me instead of listing everything" do
      get "/cli/v1/projects/#{project.id}/tickets", params: { assignee: "someone" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-015")
    end
  end

  it "show → 200 con code e title" do
    ticket = create(:ticket, project:, organization:)
    get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers
    data = response.parsed_body["data"]
    expect(data["id"]).to eq(ticket.id)
    expect(data["code"]).to eq(ticket.code)
  end

  describe "GET show — corpo completo (canale d'analisi: la CLI vede tutto ciò che vede la show web)" do
    it "bug: espone description, scenari BDD, DoD, analisi tecnica, weight, persone, milestone e platforms" do
      platform = create(:platform, organization:)
      project.platforms << platform
      milestone = create(:milestone, project:)
      assignee = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
      ticket = create(:ticket, project:, organization:, with_default_body: false,
                      description: "Contesto generale del bug",
                      technical_analysis: "stack trace + N+1 su Dashboard#show",
                      scenarios_attributes: [ { title: "Login", step_given: "utente loggato", step_when: "apre la dashboard",
                                                step_then: "errore 500", step_expected: "dashboard caricata" } ],
                      conditions_attributes: [ { text: "la dashboard carica senza errori" } ],
                      weight: 3, assignee:, milestone:, platforms: [ platform ])

      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["description"]).to eq("Contesto generale del bug")
      expect(data["technical_analysis"]).to eq("stack trace + N+1 su Dashboard#show")
      expect(data["scenarios"].first).to include("step_given" => "utente loggato", "step_expected" => "dashboard caricata")
      expect(data["conditions"]).to eq([ { "text" => "la dashboard carica senza errori" } ])
      expect(data["weight"]).to eq(3)
      expect(data["votes_count"]).to eq(0)
      expect(data["assignee"]).to eq(assignee.name)
      expect(data["reporter"]).to eq(ticket.reporter.name)
      expect(data["reviewer"]).to eq(ticket.reviewer.name)
      expect(data["milestone"]).to eq(milestone.label)
      expect(data["platforms"]).to eq([ platform.label ])
    end

    it "feature: description presente, scenari e DoD vuoti, analisi tecnica e riferimenti opzionali null" do
      ticket = create(:ticket, :story, project:, organization:, assignee: nil, milestone: nil)

      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["description"]).to eq(ticket.description)
      expect(data["scenarios"]).to eq([])
      expect(data["conditions"]).to eq([])
      expect(data["technical_analysis"]).to be_nil
      expect(data["assignee"]).to be_nil
      expect(data["milestone"]).to be_nil
      expect(data["platforms"]).to eq([])
    end
  end

  describe "GET show per code umano (KEY-n)" do
    let!(:ticket) { create(:ticket, project:, organization:) }

    it "risolve il code → 200 con lo stesso ticket" do
      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(ticket.id)
    end

    it "case-insensitive (code minuscolo)" do
      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.code.downcase}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(ticket.id)
    end

    it "numero inesistente → 404" do
      get "/cli/v1/projects/#{project.id}/tickets/#{project.key}-999999", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "code di un ALTRO progetto → 404 (mai lookup cross-progetto)" do
      other_project = create(:project, organization:)
      other = create(:ticket, project: other_project, organization:)

      get "/cli/v1/projects/#{project.id}/tickets/#{other.code}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "ref malformato (né UUID né code) → 404" do
      get "/cli/v1/projects/#{project.id}/tickets/garbage-ref", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "update per code → 200 (stesso lookup dei sub-endpoint)" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}", headers: headers, params: {
        title: "Aggiornato via code", kind: "bug",
        scenarios_attributes: [ { step_given: "g", step_when: "w", step_then: "t", step_expected: "e" } ],
        status_id: ticket.status_id, priority_id: ticket.priority_id
      }

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.title).to eq("Aggiornato via code")
    end
  end

  it "create → 201 con un bug valido (uno scenario BDD)" do
    status = create(:ticket_status, organization:)
    priority = create(:ticket_priority, organization:)

    expect do
      post "/cli/v1/projects/#{project.id}/tickets", headers: headers, params: {
        title: "Crash al login", kind: "bug",
        scenarios_attributes: [ { step_given: "utente loggato", step_when: "apre la dashboard",
                                  step_then: "errore 500", step_expected: "dashboard caricata" } ],
        status_id: status.id, priority_id: priority.id
      }
    end.to change(Ticketing::Ticket, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body["data"]["title"]).to eq("Crash al login")
  end

  it "create → 201 con scenari multipli, DoD e analisi tecnica (parità piena col web)" do
    status = create(:ticket_status, organization:)
    priority = create(:ticket_priority, organization:)

    post "/cli/v1/projects/#{project.id}/tickets", headers: headers, params: {
      title: "Checkout", kind: "bug", technical_analysis: "timeout gateway 30s",
      scenarios_attributes: [
        { title: "Happy", step_given: "loggato", step_when: "compra", step_then: "ok" },
        { title: "Errore", step_when: "compra", step_then: "500" }
      ],
      conditions_attributes: [ { text: "arriva la mail" } ],
      status_id: status.id, priority_id: priority.id
    }

    expect(response).to have_http_status(:created)
    ticket = Ticketing::Ticket.last
    expect(ticket.scenarios.map(&:title)).to eq([ "Happy", "Errore" ])
    expect(ticket.conditions.map(&:text)).to eq([ "arriva la mail" ])
    expect(ticket.technical_analysis).to eq("timeout gateway 30s")
    expect(response.parsed_body["data"]["scenarios"].size).to eq(2)
  end

  it "create → 201 con un bug da solo testo semplice (descrizione, nessuna clausola)" do
    status = create(:ticket_status, organization:)
    priority = create(:ticket_priority, organization:)

    expect do
      post "/cli/v1/projects/#{project.id}/tickets", headers: headers, params: {
        title: "Login rotto", kind: "bug", description: "La dashboard va in errore 500 dopo il login",
        status_id: status.id, priority_id: priority.id
      }
    end.to change(Ticketing::Ticket, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(Ticketing::Ticket.last.description).to eq("La dashboard va in errore 500 dopo il login")
  end

  it "create con parent_id → aggancia l'epic e la espone nel serializer (id + code)" do
    status = create(:ticket_status, organization:)
    priority = create(:ticket_priority, organization:)
    epic = create(:ticket, :epic, organization:, project:, status:, priority:)

    post "/cli/v1/projects/#{project.id}/tickets", headers: headers, params: {
      title: "Pagamento con carta", kind: "story", description: "serve pagare con carta",
      status_id: status.id, priority_id: priority.id, parent_id: epic.id
    }

    expect(response).to have_http_status(:created)
    expect(response.parsed_body["data"]["parent_id"]).to eq(epic.id)
    expect(response.parsed_body["data"]["parent"]).to eq(epic.code)
  end

  it "update con parent_id vuoto → stacca il ticket dall'epic" do
    status = create(:ticket_status, organization:)
    priority = create(:ticket_priority, organization:)
    epic = create(:ticket, :epic, organization:, project:, status:, priority:)
    ticket = create(:ticket, :story, organization:, project:, parent: epic, status:, priority:)

    put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers, params: {
      title: ticket.title, kind: "story", description: "corpo",
      status_id: status.id, priority_id: priority.id, parent_id: ""
    }

    expect(response).to have_http_status(:ok)
    expect(ticket.reload.parent).to be_nil
    expect(response.parsed_body["data"]["parent"]).to be_nil
  end

  it "create con kind legacy `feature` → 422 (taglio netto sui vecchi nomi)" do
    status = create(:ticket_status, organization:)
    priority = create(:ticket_priority, organization:)

    post "/cli/v1/projects/#{project.id}/tickets", headers: headers, params: {
      title: "Vecchio nome", kind: "feature", description: "corpo",
      status_id: status.id, priority_id: priority.id
    }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "create senza title → 422 R422-TICKET-001" do
    post "/cli/v1/projects/#{project.id}/tickets", headers: headers, params: { kind: "bug" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-001")
  end

  it "create con due_at → salva la scadenza e la espone nel serializer" do
    status = create(:ticket_status, organization:)
    priority = create(:ticket_priority, organization:)

    post "/cli/v1/projects/#{project.id}/tickets", headers: headers, params: {
      title: "Scadenza", kind: "bug", description: "va fatto entro",
      due_at: "2026-08-01T17:00", status_id: status.id, priority_id: priority.id
    }

    expect(response).to have_http_status(:created)
    expect(Ticketing::Ticket.last.due_at.strftime("%Y-%m-%d %H:%M")).to eq("2026-08-01 17:00")
    expect(response.parsed_body["data"]).to have_key("due_at")
  end

  it "ticket di un'altra org → 404 (anti-BOLA)" do
    other = create(:ticket, organization: create(:organization))
    get "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/tickets"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "PUT update (gate tickets.edit)" do
    let!(:ticket) { create(:ticket, project:, organization:, title: "Vecchio") }

    it "owner aggiorna i campi del bug → 200 + dati nuovi" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers, params: {
        title: "Nuovo titolo", kind: "bug",
        scenarios_attributes: [ { step_given: "g", step_when: "w", step_then: "t", step_expected: "e" } ],
        status_id: ticket.status_id, priority_id: ticket.priority_id
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["title"]).to eq("Nuovo titolo")
      expect(ticket.reload.title).to eq("Nuovo titolo")
    end

    it "sostituisce gli scenari esistenti invece di accumularli (replace)" do
      t = create(:ticket, :with_scenarios, project:, organization:, scenarios_count: 2)
      put "/cli/v1/projects/#{project.id}/tickets/#{t.id}", headers: headers, params: {
        title: "Con nuovo scenario", kind: "bug",
        scenarios_attributes: [ { step_given: "unico", step_when: "w", step_then: "t" } ],
        status_id: t.status_id, priority_id: t.priority_id
      }

      expect(response).to have_http_status(:ok)
      expect(t.reload.scenarios.count).to eq(1)
      expect(t.scenarios.first.step_given).to eq("unico")
    end

    it "validazione fallita (titolo vuoto) → 422 R422-TICKET-002" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers, params: {
        title: "", kind: "bug",
        scenarios_attributes: [ { step_given: "g", step_when: "w", step_then: "t", step_expected: "e" } ],
        status_id: ticket.status_id, priority_id: ticket.priority_id
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TICKET-002")
    end

    it "ticket di un'altra org → 404 (anti-BOLA), set_project! fallisce prima del gate" do
      other = create(:ticket, organization: create(:organization))
      put "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}", headers: headers, params: { title: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "ticket di un altro progetto della stessa org → 404 (scope progetto)" do
      other_project = create(:project, organization:)
      other_ticket = create(:ticket, project: other_project, organization:)
      put "/cli/v1/projects/#{project.id}/tickets/#{other_ticket.id}", headers: headers, params: { title: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.edit → 403" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: member_headers, params: { title: "x" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(ticket.reload.title).to eq("Vecchio")
    end

    it "senza bearer → 401" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", params: { title: "x" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE destroy (gate tickets.delete)" do
    let!(:ticket) { create(:ticket, project:, organization:) }

    it "owner elimina → 204 e ticket rimosso" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Ticketing::Ticket.exists?(ticket.id)).to be(false)
    end

    it "ticket di un'altra org → 404 (anti-BOLA) e ticket invariato" do
      other = create(:ticket, organization: create(:organization))
      delete "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(Ticketing::Ticket.exists?(other.id)).to be(true)
    end

    it "membro che vede il progetto ma senza tickets.delete → 403 e ticket invariato" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(Ticketing::Ticket.exists?(ticket.id)).to be(true)
    end

    it "senza bearer → 401 e ticket invariato" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(Ticketing::Ticket.exists?(ticket.id)).to be(true)
    end
  end

  describe "guidance risolta nel dettaglio (CYRA-74)" do
    let(:group) { create(:group, organization:) }
    let(:grouped_project) { create(:project, organization:, group:) }

    it "la show del ticket include references e procedures risolte del progetto, con origine" do
      ticket = create(:ticket, project: grouped_project, organization:)
      create(:guidance_reference, owner: organization, key: "org-repo")
      create(:guidance_reference, :path, owner: grouped_project, key: "proj-path")
      create(:guidance_procedure, owner: group, key: "setup", content: "Fai il setup")

      get "/cli/v1/projects/#{grouped_project.id}/tickets/#{ticket.id}", headers: headers

      guidance = response.parsed_body["data"]["guidance"]
      expect(guidance["references"].map { |r| r["key"] }).to contain_exactly("org-repo", "proj-path")
      expect(guidance["procedures"].map { |p| p["key"] }).to eq(%w[setup])
      expect(guidance["references"].find { |r| r["key"] == "proj-path" }["level"]).to eq("project")
    end

    it "una key ridefinita al progetto sostituisce quella dell'org nel payload del ticket" do
      ticket = create(:ticket, project:, organization:)
      create(:guidance_reference, owner: organization, key: "repo", location: "git@org")
      create(:guidance_reference, owner: project, key: "repo", location: "git@project")

      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers

      refs = response.parsed_body["data"]["guidance"]["references"]
      expect(refs.size).to eq(1)
      expect(refs.first["location"]).to eq("git@project")
    end

    it "la description del ticket resta invariata (la guidance non vi viene copiata)" do
      ticket = create(:ticket, project:, organization:, with_default_body: false, description: "Testo originale")
      create(:guidance_reference, owner: organization, key: "repo")

      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers

      expect(response.parsed_body["data"]["description"]).to eq("Testo originale")
    end

    it "l'index dei ticket non include la guidance (nessun costo né cambio di forma)" do
      create(:ticket, project:, organization:)

      get "/cli/v1/projects/#{project.id}/tickets", headers: headers

      expect(response.parsed_body["data"].first).not_to have_key("guidance")
    end
  end
end
