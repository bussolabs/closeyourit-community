# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Links", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }
  let(:related) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def links_path(t = ticket)
    "/cli/v1/projects/#{project.id}/tickets/#{t.id}/links"
  end

  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }
  end

  it "senza bearer → 401" do
    get links_path
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index (baseline)" do
    it "elenca i link che coinvolgono il ticket (entrambi i lati)" do
      link = create(:ticket_link, ticket:, related:, kind: :duplicate)

      get links_path, headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      row = data.find { |l| l["id"] == link.id }
      expect(row).to be_present
      expect(row["kind"]).to eq("duplicate")
      expect(row["other_ticket_id"]).to eq(related.id)
    end
  end

  # CYRA-789 — anti-BOLA in lettura (parità col web): l'altro capo può stare in un progetto che chi
  # chiama non vede. Identità oscurata (id/code → null), il FATTO resta con `hidden`.
  describe "GET index — capo del collegamento non visibile" do
    let(:hidden_project) { create(:project, organization:) }
    let(:hidden_ticket) { create(:ticket, project: hidden_project, organization:, title: "Segreto di un altro progetto") }

    it "oscura identità e codice del capo fuori scope" do
      link = create(:ticket_link, ticket:, related: hidden_ticket, kind: :related)

      get links_path, headers: member_headers

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].find { |l| l["id"] == link.id }
      expect(row["hidden"]).to be(true)
      expect(row["kind"]).to eq("related")
      expect(row["other_ticket_id"]).to be_nil
      expect(row["other_ticket_code"]).to be_nil
      expect(row["related_id"]).to be_nil
      expect(row["ticket_id"]).to eq(ticket.id)
      expect(response.body).not_to include(hidden_ticket.id)
    end

    it "oscura anche nel verso opposto (capo nascosto come sorgente)" do
      link = create(:ticket_link, ticket: hidden_ticket, related: ticket, kind: :related)

      get links_path, headers: member_headers

      row = response.parsed_body["data"].find { |l| l["id"] == link.id }
      expect(row["hidden"]).to be(true)
      expect(row["ticket_id"]).to be_nil
      expect(row["related_id"]).to eq(ticket.id)
      expect(response.body).not_to include(hidden_ticket.id)
    end

    it "chi vede entrambi i progetti riceve il collegamento per intero" do
      link = create(:ticket_link, ticket:, related: hidden_ticket, kind: :related)

      get links_path, headers: headers

      row = response.parsed_body["data"].find { |l| l["id"] == link.id }
      expect(row["hidden"]).to be(false)
      expect(row["other_ticket_id"]).to eq(hidden_ticket.id)
      expect(row["other_ticket_code"]).to eq(hidden_ticket.code)
    end
  end

  describe "DELETE destroy (gate tickets.edit)" do
    it "owner rimuove il link → 204" do
      link = create(:ticket_link, ticket:, related:)

      delete "#{links_path}/#{link.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Connections::TicketLink.exists?(link.id)).to be(false)
    end

    it "membro che vede il ticket ma senza tickets.edit → 403, link invariato" do
      link = create(:ticket_link, ticket:, related:)

      delete "#{links_path}/#{link.id}", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(Connections::TicketLink.exists?(link.id)).to be(true)
    end

    it "link che non coinvolge il ticket → 404 (anti-BOLA)" do
      foreign = create(:ticket_link, organization:)

      delete "#{links_path}/#{foreign.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "ticket di un'altra org → 404" do
      other = create(:ticket, organization: create(:organization))
      delete "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/links/00000000-0000-0000-0000-000000000000",
             headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
