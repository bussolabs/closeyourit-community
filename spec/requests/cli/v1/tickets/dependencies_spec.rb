# frozen_string_literal: true

require "rails_helper"

# Dipendenze (prerequisiti) tra ticket sul canale CLI (CYRA-83): A DIPENDE dal blocker B. index è
# baseline (chi vede il ticket); create/destroy gated tickets.edit. La logica vive nei service
# condivisi col web (Ticketing::AddDependency/RemoveDependency) → parità di codici errore col canale
# Member. Prosopite gira su ogni request spec (spec/support/prosopite.rb): l'index con più voci è di
# per sé la guardia N+1 richiesta dalla Definition of Done.
RSpec.describe "Cli::V1::Tickets::Dependencies", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:open_status) { create(:ticket_status, organization:, code: "open", label: "Open") }
  let(:done_status) { create(:ticket_status, organization:, code: "done", label: "Resolved", category: :done) }
  let(:ticket) { create(:ticket, project:, organization:, status: open_status) }
  let(:blocker) { create(:ticket, project:, organization:, status: open_status) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def deps_path(t = ticket)
    "/cli/v1/projects/#{project.id}/tickets/#{t.id}/dependencies"
  end

  # Membro che VEDE il progetto ma è privo di tickets.edit (baseline lettura, non scrittura).
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }
  end

  it "senza bearer → 401" do
    get deps_path
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index (baseline: chi vede il ticket)" do
    it "elenca le dipendenze: code, title, status (id+code+category) e done" do
      done_blocker = create(:ticket, project:, organization:, status: done_status)
      create(:ticket_dependency, ticket:, blocker:)                 # blocker aperto → non done
      create(:ticket_dependency, ticket:, blocker: done_blocker)    # blocker done → done

      get deps_path, headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.size).to eq(2)

      open_row = data.find { |row| row["blocker_id"] == blocker.id }
      expect(open_row["code"]).to eq(blocker.code)
      expect(open_row["title"]).to eq(blocker.title)
      expect(open_row["status"]).to include("id" => open_status.id, "code" => "open", "category" => "open")
      expect(open_row["done"]).to be(false)

      done_row = data.find { |row| row["blocker_id"] == done_blocker.id }
      expect(done_row["status"]).to include("code" => "done", "category" => "done")
      expect(done_row["done"]).to be(true)
    end

    it "è accessibile a un membro senza tickets.edit (sola visibilità)" do
      create(:ticket_dependency, ticket:, blocker:)

      get deps_path, headers: member_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(1)
    end

    it "ticket in un progetto non visibile al membro → 404 (anti-BOLA)" do
      hidden = create(:project, organization:)
      hidden_ticket = create(:ticket, project: hidden, organization:, status: open_status)

      get "/cli/v1/projects/#{hidden.id}/tickets/#{hidden_ticket.id}/dependencies", headers: member_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # Anti-BOLA in LETTURA (parità col web, CYRA-82): un blocker cross-project (ammesso) può stare in un
  # progetto che chi guarda A non vede — identità (blocker_id/code/title) da nascondere, stato conservato.
  describe "GET index — blocker cross-project non visibile" do
    it "oscura blocker_id/code/title del blocker fuori scope, conserva stato e id dipendenza" do
      hidden_project = create(:project, organization:)
      hidden_blocker = create(:ticket, project: hidden_project, organization:, status: open_status, title: "Segreto di un altro progetto")
      dependency = create(:ticket_dependency, ticket:, blocker: hidden_blocker)

      get deps_path, headers: member_headers

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].find { |r| r["id"] == dependency.id }
      expect(row["hidden"]).to be(true)
      expect(row["blocker_id"]).to be_nil
      expect(row["code"]).to be_nil
      expect(row["title"]).to be_nil
      expect(row["status"]).to be_present # lo stato (org-wide) resta: serve a sapere se è risolto
      expect(row.to_json).not_to include("Segreto di un altro progetto")
      expect(row.to_json).not_to include(hidden_blocker.code)
    end

    it "un blocker visibile resta esposto per intero" do
      create(:ticket_dependency, ticket:, blocker:)

      get deps_path, headers: member_headers

      row = response.parsed_body["data"].first
      expect(row["hidden"]).to be(false)
      expect(row["code"]).to eq(blocker.code)
      expect(row["blocker_id"]).to eq(blocker.id)
    end
  end

  describe "POST create (gate tickets.edit)" do
    it "owner aggiunge il prerequisito → 201, passa per AddDependency (record + evento + created_by)" do
      expect { post deps_path, params: { blocker: blocker.id }, headers: headers }
        .to change(Connections::TicketDependency, :count).by(1)

      expect(response).to have_http_status(:created)
      dependency = Connections::TicketDependency.last
      expect(response.parsed_body.dig("data", "id")).to eq(dependency.id)
      expect(response.parsed_body.dig("data", "blocker_id")).to eq(blocker.id)
      expect(dependency.created_by).to eq(account)
      expect(ticket.events.where(action: "dependency_added")).to exist
    end

    it "accetta il blocker per code umano KEY-N cross-project intra-org → 201" do
      cross_project = create(:project, organization:)
      cross_blocker = create(:ticket, project: cross_project, organization:, status: open_status)

      expect { post deps_path, params: { blocker: cross_blocker.code }, headers: headers }
        .to change(Connections::TicketDependency, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(Connections::TicketDependency.last.blocker_id).to eq(cross_blocker.id)
    end

    it "duplicato → 422 R422-TICKET-017, nessun secondo record" do
      create(:ticket_dependency, ticket:, blocker:)

      expect { post deps_path, params: { blocker: blocker.id }, headers: headers }
        .not_to change(Connections::TicketDependency, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-017")
    end

    it "ciclo → 422 R422-TICKET-013 (parità col web)" do
      create(:ticket_dependency, ticket: blocker, blocker: ticket)

      post deps_path, params: { blocker: blocker.id }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-013")
    end

    it "membro senza tickets.edit → 403 R403-CLIAUTH-002, nessun record" do
      expect { post deps_path, params: { blocker: blocker.id }, headers: member_headers }
        .not_to change(Connections::TicketDependency, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-CLIAUTH-002")
    end

    it "blocker di un'altra org → 404 R404-TICKET-015, nessun leak" do
      other_org = create(:organization)
      foreign = create(:ticket, organization: other_org, project: create(:project, organization: other_org))

      expect { post deps_path, params: { blocker: foreign.id }, headers: headers }
        .not_to change(Connections::TicketDependency, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-TICKET-015")
    end

    it "ticket principale in un progetto non visibile al membro → 404 (anti-BOLA)" do
      hidden = create(:project, organization:)
      hidden_ticket = create(:ticket, project: hidden, organization:, status: open_status)

      post "/cli/v1/projects/#{hidden.id}/tickets/#{hidden_ticket.id}/dependencies",
           params: { blocker: blocker.id }, headers: member_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy (gate tickets.edit, per UUID dependency)" do
    it "owner rimuove la dipendenza → 204" do
      dependency = create(:ticket_dependency, ticket:, blocker:)

      expect { delete "#{deps_path}/#{dependency.id}", headers: headers }
        .to change(Connections::TicketDependency, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "membro senza tickets.edit → 403, dipendenza invariata" do
      dependency = create(:ticket_dependency, ticket:, blocker:)

      delete "#{deps_path}/#{dependency.id}", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(Connections::TicketDependency.exists?(dependency.id)).to be(true)
    end

    it "dependency UUID di un altro ticket → 404 R404-TICKET-016, nessuna rimozione (anti-BOLA)" do
      other_ticket = create(:ticket, project:, organization:, status: open_status)
      foreign = create(:ticket_dependency, ticket: other_ticket, blocker:)

      expect { delete "#{deps_path}/#{foreign.id}", headers: headers }
        .not_to change(Connections::TicketDependency, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-TICKET-016")
    end

    it "id inesistente → 404 (idempotenza: non 500)" do
      delete "#{deps_path}/#{SecureRandom.uuid}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "ticket di un'altra org → 404" do
      other = create(:ticket, organization: create(:organization))
      delete "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/dependencies/#{SecureRandom.uuid}",
             headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # blocked/workable + status stabile nel TicketSerializer (index dei ticket): SNAPSHOT anti-N+1 (il Set
  # "bloccato" è precalcolato con una query aggregata; Prosopite verifica l'assenza di N+1 sulla lista).
  describe "GET /cli/v1/projects/:id/tickets — blocked/workable + status_ref" do
    it "espone blocked/workable coerenti e lo status stabile id/code/category oltre alla label" do
      create(:ticket_dependency, ticket:, blocker:) # blocker aperto → ticket bloccato
      free_ticket = create(:ticket, project:, organization:, status: open_status)

      get "/cli/v1/projects/#{project.id}/tickets", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      blocked_row = data.find { |row| row["id"] == ticket.id }
      free_row = data.find { |row| row["id"] == free_ticket.id }

      expect(blocked_row["blocked"]).to be(true)
      expect(blocked_row["workable"]).to be(false)
      expect(free_row["blocked"]).to be(false)
      expect(free_row["workable"]).to be(true)

      expect(blocked_row["status"]).to eq(open_status.label)
      expect(blocked_row["status_ref"]).to include("id" => open_status.id, "code" => "open", "category" => "open")
    end
  end
end
