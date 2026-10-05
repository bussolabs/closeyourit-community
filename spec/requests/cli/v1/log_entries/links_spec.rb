# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::LogEntries::Links", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:entry) { create(:log_entry, project:) }
  let(:group) { create(:error_group, project:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def links_path(log = entry)
    "/cli/v1/log_entries/#{log.id}/links"
  end

  it "senza bearer → 401" do
    post links_path, params: { linkable: "Errors::Group:#{group.id}" }
    expect(response).to have_http_status(:unauthorized)
  end

  describe "POST create (collega, gate logs.link)" do
    it "collega il log a un error group dello stesso progetto → 201" do
      expect do
        post links_path, headers: headers, params: { linkable: "Errors::Group:#{group.id}" }
      end.to change { entry.links.count }.by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["linkable_type"]).to eq("Errors::Group")
      expect(data["linkable_id"]).to eq(group.id)
    end

    it "è idempotente: ricollegare lo stesso target resta 201 con un solo link" do
      post links_path, headers: headers, params: { linkable: "Errors::Group:#{group.id}" }
      post links_path, headers: headers, params: { linkable: "Errors::Group:#{group.id}" }

      expect(response).to have_http_status(:created)
      expect(entry.links.count).to eq(1)
    end

    it "tipo non ammesso → 422 R422-LOG-003 (nessun link)" do
      expect do
        post links_path, headers: headers, params: { linkable: "Projects::Project:#{project.id}" }
      end.not_to change(Logs::Link, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-LOG-003")
    end

    it "target di un ALTRO progetto → 422 R422-LOG-003 (anti-BOLA, non collegabile)" do
      foreign_group = create(:error_group, project: create(:project, organization:))

      post links_path, headers: headers, params: { linkable: "Errors::Group:#{foreign_group.id}" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-LOG-003")
    end

    it "log di un progetto non visibile → 404 (anti-BOLA, prima del gate)" do
      foreign_entry = create(:log_entry, project: create(:project))

      post links_path(foreign_entry), headers: headers, params: { linkable: "Errors::Group:#{group.id}" }

      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza logs.link → 403, nessun link" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      member_headers = { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }

      expect do
        post links_path, headers: member_headers, params: { linkable: "Errors::Group:#{group.id}" }
      end.not_to change(Logs::Link, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  describe "DELETE destroy (scollega)" do
    it "rimuove il collegamento → 204" do
      link = create(:log_link, log_entry: entry, linkable: group)

      delete "#{links_path}/#{link.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Logs::Link.exists?(link.id)).to be(false)
    end

    it "link inesistente → 404 (anti-BOLA)" do
      delete "#{links_path}/00000000-0000-0000-0000-000000000000", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
