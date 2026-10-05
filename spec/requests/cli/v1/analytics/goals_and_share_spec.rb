# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Analytics goals & share", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  # Progetto analytics-collecting (piattaforma web supports_analytics + toggle attivo): goals/share, come
  # il web, esistono solo su questi.
  let(:project) do
    create(:project, organization:, analytics_enabled: true).tap do |p|
      p.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
    end
  end

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def goals_path(proj = project)
    "/cli/v1/projects/#{proj.id}/analytics/goals"
  end

  def share_path(proj = project)
    "/cli/v1/projects/#{proj.id}/analytics/share"
  end

  describe "goals" do
    it "senza bearer → 401" do
      get goals_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "index → 200 con i goal del progetto" do
      goal = create(:analytics_goal, project:)

      get goals_path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |g| g["id"] }).to include(goal.id)
    end

    it "create pageview_path → 201" do
      expect do
        post goals_path, headers: headers,
                         params: { kind: "pageview_path", path_pattern: "/checkout", display_name: "Checkout" }
      end.to change(Analytics::Goal, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("kind" => "pageview_path", "display_name" => "Checkout")
    end

    it "create custom_event → 201" do
      post goals_path, headers: headers,
                       params: { kind: "custom_event", event_name: "Signup", display_name: "Registrazione" }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["event_name"]).to eq("Signup")
    end

    it "create senza display_name → 422 R422-GOAL-001" do
      post goals_path, headers: headers, params: { kind: "pageview_path", path_pattern: "/x" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-GOAL-001")
    end

    it "destroy → 204 e rimuove il goal" do
      goal = create(:analytics_goal, project:)

      delete "#{goals_path}/#{goal.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Analytics::Goal.exists?(goal.id)).to be(false)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project)
      get goals_path(other), headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "progetto visibile ma NON analytics-collecting → 404 (parità web)" do
      plain = create(:project, organization:) # visibile all'owner ma senza analytics

      get goals_path(plain), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "share (link pubblico)" do
    it "create → 201 con slug" do
      expect do
        post share_path, params: { confirm: "1" }, headers: headers
      end.to change(Analytics::Link, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["slug"]).to be_present
    end

    it "destroy revoca il link attivo → 204" do
      create(:analytics_link, project:)

      delete share_path, params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(project.analytics_links.active).to be_empty
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project)
      post share_path(other), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
