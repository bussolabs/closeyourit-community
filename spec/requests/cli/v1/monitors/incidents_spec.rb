# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Monitors::Incidents", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) do
    create(:project, organization:).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization:))
    end
  end
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:monitor) { create(:uptime_monitor, project:, environment:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def base = "/cli/v1/projects/#{project.id}/monitors/#{monitor.id}/incidents"

  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }
  end

  describe "POST incidents/group (unifica + primo step)" do
    it "raggruppa due incident dello stesso monitor → 201" do
      i1 = create(:uptime_incident, monitor:)
      i2 = create(:uptime_incident, monitor:)

      post "#{base}/group", headers: headers,
                            params: { incident_ids: [ i1.id, i2.id ], phase: "investigating", body: "Unifico" }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("phase" => "investigating")
    end

    it "incident_ids vuoti/non validi → 422 R422-UPTIME-001" do
      post "#{base}/group", headers: headers, params: { incident_ids: [], phase: "investigating" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-UPTIME-001")
    end

    it "membro senza uptime.manage → 403" do
      i1 = create(:uptime_incident, monitor:)
      i2 = create(:uptime_incident, monitor:)

      post "#{base}/group", headers: member_headers,
                            params: { incident_ids: [ i1.id, i2.id ], phase: "investigating" }
      expect(response).to have_http_status(:forbidden)
    end

    it "monitor di un'altra org → 404 (anti-BOLA)" do
      other = create(:uptime_monitor)
      post "/cli/v1/projects/#{project.id}/monitors/#{other.id}/incidents/group",
           headers: headers, params: { incident_ids: [], phase: "investigating" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE incidents/:id/group (scioglie il raggruppamento)" do
    it "scioglie → 204" do
      i1 = create(:uptime_incident, monitor:)
      i2 = create(:uptime_incident, monitor:)
      primary = Uptime::Incidents::GroupAndUpdate.call(
        monitor:, incident_ids: [ i1.id, i2.id ], phase: "investigating", body: "x", actor: account
      ).value

      delete "#{base}/#{primary.id}/group", headers: headers

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "DELETE incidents/:id (elimina l'incident primary)" do
    it "elimina → 204 e incident rimosso" do
      incident = create(:uptime_incident, monitor:)

      delete "#{base}/#{incident.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Uptime::Incident.exists?(incident.id)).to be(false)
    end

    it "un incident FIGLIO (non top_level) → 404" do
      primary = create(:uptime_incident, monitor:)
      child = create(:uptime_incident, monitor:, parent: primary)

      delete "#{base}/#{child.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "membro senza uptime.manage → 403" do
      incident = create(:uptime_incident, monitor:)
      delete "#{base}/#{incident.id}", headers: member_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "incidents/:incident_id/updates (step della narrazione)" do
    let(:incident) { create(:uptime_incident, :narrated, monitor:) }

    it "POST aggiunge uno step → 201" do
      post "#{base}/#{incident.id}/updates", headers: headers,
                                             params: { phase: "fixing", body: "Applicata la fix" }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("phase" => "fixing", "body" => "Applicata la fix")
    end

    it "POST con phase non valida → 422 R422-UPTIME-002" do
      post "#{base}/#{incident.id}/updates", headers: headers, params: { phase: "nonexistent" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-UPTIME-002")
    end

    it "DELETE rimuove uno step → 204" do
      step = create(:uptime_incident_update, incident:)

      delete "#{base}/#{incident.id}/updates/#{step.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Uptime::IncidentUpdate.exists?(step.id)).to be(false)
    end

    it "membro senza uptime.manage → POST 403" do
      post "#{base}/#{incident.id}/updates", headers: member_headers, params: { phase: "fixing" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
