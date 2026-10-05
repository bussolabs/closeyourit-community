# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Analytics::Goals", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  let(:project) { create(:project, organization: org, analytics_enabled: true).tap { |p| p.platforms << web } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "200 con i goal del progetto" do
      create(:analytics_goal, project:, display_name: "Visita pricing")
      get member_monitoring_analytics_goals_path(project_id: project.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Visita pricing")
    end

    # CYRA-924 — goal and kind sort (C9).
    it "sorts by goal both ways and offers every column" do
      create(:analytics_goal, project:, display_name: "Zeta signup")
      create(:analytics_goal, project:, display_name: "alpha pricing", path_pattern: "/alpha")
      get member_monitoring_analytics_goals_path(project_id: project.id, sort: "-goal")
      expect(response.body.index("Zeta signup")).to be < response.body.index("alpha pricing")
      get member_monitoring_analytics_goals_path(project_id: project.id, sort: "goal")
      expect(response.body.index("alpha pricing")).to be < response.body.index("Zeta signup")
      %w[goal kind].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end

    it "BOLA: progetto di un'altra org → 404" do
      other = create(:organization)
      Types::InstallDefaults.call(organization: other)
      foreign = create(:project, organization: other, analytics_enabled: true)
        .tap { |p| p.platforms << Types::Platform.find_by!(organization: other, code: "web") }

      get member_monitoring_analytics_goals_path(project_id: foreign.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET new" do
    it "200 con il form" do
      get new_member_monitoring_analytics_goal_path(project_id: project.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"analytics-goal-form\"")
    end
  end

  describe "POST create" do
    it "crea un goal pageview_path e reindirizza all'index" do
      expect do
        post member_monitoring_analytics_goals_path(project_id: project.id),
             params: { analytics_goal: { kind: "pageview_path", path_pattern: "/pricing", display_name: "Pricing" } }
      end.to change(Analytics::Goal, :count).by(1)

      expect(response).to redirect_to(member_monitoring_analytics_goals_path(project_id: project.id))
    end

    it "crea un goal custom_event" do
      expect do
        post member_monitoring_analytics_goals_path(project_id: project.id),
             params: { analytics_goal: { kind: "custom_event", event_name: "Signup", display_name: "Iscrizione" } }
      end.to change(Analytics::Goal, :count).by(1)
    end

    it "dati invalidi → 422 e ri-render del form" do
      post member_monitoring_analytics_goals_path(project_id: project.id),
           params: { analytics_goal: { kind: "pageview_path", path_pattern: "", display_name: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("data-test=\"analytics-goal-form\"")
    end
  end

  describe "DELETE destroy" do
    it "elimina il goal e reindirizza" do
      goal = create(:analytics_goal, project:)
      expect do
        delete member_monitoring_analytics_goal_path(goal, project_id: project.id)
      end.to change(Analytics::Goal, :count).by(-1)

      expect(response).to redirect_to(member_monitoring_analytics_goals_path(project_id: project.id))
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      goal = create(:analytics_goal, project:, display_name: "Visita pricing")

      get member_monitoring_analytics_goals_path(project_id: project.id)

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='analytics-goal-delete-dialog-#{goal.id}']")
      expect(dialog.text).to include(I18n.t("member.monitoring.analytics.goals.delete_dialog.title", name: "Visita pricing"))
      expect(dialog.at_css("form")["action"]).to eq(member_monitoring_analytics_goal_path(goal, project_id: project.id))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(dialog.ancestors.first.at_css("[data-test='analytics-goals-delete']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
