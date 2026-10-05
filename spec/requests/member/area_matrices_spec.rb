# frozen_string_literal: true

require "rails_helper"

# CYRA-930 — every area landing is a table like Observability: a row per visible project, a column
# per signal, the number linking to the list filtered on that project. The cards that repeated the
# sidebar entries are gone.
RSpec.describe "Member — area landings as project tables", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, name: "Payments API") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  def row(area, id) = body.at_css(%([data-test="#{area}-row-#{id}"]))

  def cell(area, id, key) = row(area, id)&.at_css(%([data-test="#{area}-cell-#{key}"]))

  def value(area, id, key) = cell(area, id, key).at_css(%([data-test="#{area}-cell-value"])).text.strip

  describe "Product" do
    it "counts open, in progress, overdue and unassigned tickets and open ideas per project" do
      in_progress = create(:ticket_status, organization:, category: :in_progress)
      done = create(:ticket_status, organization:, category: :done)
      create(:ticket, project:, assignee: owner)
      create(:ticket, project:, status: in_progress, assignee: owner)
      create(:ticket, project:, due_at: 2.days.ago)
      create(:ticket, project:, status: done, due_at: 2.days.ago)
      create(:idea, project:, author: owner)
      sign_in(owner)

      get member_product_path

      expect(response).to have_http_status(:ok)
      expect(value("product", project.id, "open")).to eq("3")
      expect(value("product", project.id, "in_progress")).to eq("1")
      expect(value("product", project.id, "overdue")).to eq("1")
      expect(value("product", project.id, "unassigned")).to eq("1")
      expect(value("product", project.id, "ideas")).to eq("1")
      expect(value("product", "all", "open")).to eq("3")
      expect(cell("product", project.id, "open")["href"]).to eq(list_member_tickets_path(ft: 1, project_id: [ project.id ], status_id: organization.ticket_statuses.where.not(category: :done).ids))
      expect(cell("product", project.id, "ideas")["href"]).to eq(member_ideas_path(project_id: [ project.id ]))
      expect(body.at_css('[data-test="product-overview-group"]')).to be_nil
    end

    it "leaves out the projects the account cannot see" do
      project
      create(:project, name: "Someone else's")
      sign_in(owner)

      get member_product_path

      expect(row("product", project.id)).to be_present
      expect(response.body).not_to include(ERB::Util.html_escape("Someone else's"))
    end
  end

  describe "Infrastructure" do
    it "counts the sites down, the jobs late and the certificates expiring per project" do
      create(:uptime_monitor, :down, project:)
      create(:uptime_monitor, project:, current_status: :up, ssl_expires_at: 3.days.from_now, ssl_expiry_warn_days: 14)
      create(:cron_monitor, project:, status: :missed)
      create(:cron_monitor, project:, status: :ok)
      sign_in(owner)

      get member_infrastructure_path

      expect(response).to have_http_status(:ok)
      expect(value("infrastructure", project.id, "uptime")).to eq("1")
      expect(cell("infrastructure", project.id, "uptime").text).to include("2")
      expect(value("infrastructure", project.id, "crons")).to eq("1")
      expect(value("infrastructure", project.id, "certificates")).to eq("1")
      expect(cell("infrastructure", project.id, "uptime")["href"])
        .to eq(member_monitoring_monitors_path(project_id: [ project.id ]))
      expect(body.at_css('[data-test="infrastructure-signals"]')).to be_nil
    end

    it "does not count the checks of a project the account cannot see" do
      project
      create(:uptime_monitor, :down, project: create(:project, organization:))
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      sign_in(member)

      get member_infrastructure_path

      expect(cell("infrastructure", "all", "uptime")["data-state"]).to eq("off")
    end

    it "shows a project with no check as one to set up" do
      project
      sign_in(owner)

      get member_infrastructure_path

      expect(cell("infrastructure", project.id, "uptime")["data-state"]).to eq("off")
      expect(cell("infrastructure", project.id, "crons")["data-state"]).to eq("off")
      expect(cell("infrastructure", project.id, "certificates")["data-state"]).to eq("na")
    end
  end

  describe "Alerts" do
    it "counts the project's own rules, the muted ones and the account's notifications per project" do
      create(:alerting_rule, organization:, project:)
      create(:alerting_rule, organization:, project:, muted_until: 1.day.from_now)
      create(:alerting_rule, organization:)
      create(:alerting_notification, :unread, organization:, account: owner, project:)
      create(:alerting_notification, organization:, account: owner, project:, read_at: 1.hour.ago)
      sign_in(owner)

      get member_alerts_path

      expect(response).to have_http_status(:ok)
      expect(value("alerts", project.id, "rules")).to eq("2")
      expect(value("alerts", project.id, "muted")).to eq("1")
      expect(value("alerts", project.id, "unread")).to eq("1")
      expect(value("alerts", project.id, "received")).to eq("2")
      expect(value("alerts", "all", "rules")).to eq("3")
      expect(body.at_css('[data-test="alerts-overview-cards"]')).to be_nil
    end

    it "does not count the notifications of another person" do
      create(:alerting_notification, :unread, organization:, account: create(:account), project:)
      sign_in(owner)

      get member_alerts_path

      expect(value("alerts", project.id, "unread")).to eq("0")
    end
  end

  describe "Automation" do
    it "counts the decisions waiting, the automations open and stuck, and the datasets per project" do
      review = create(:ticket_status, :in_review, organization:)
      create(:ticket, project:, status: review, reviewer: owner)
      create(:agent_workflow, ticket: create(:ticket, project:))
      create(:agent_workflow, ticket: create(:ticket, project:), blocked_at: 1.hour.ago, blocked_phase: "triage",
                              blocked_kind: "attempt_limit", blocked_reason: "stuck")
      create(:dataset, project:)
      sign_in(owner)

      get member_automation_path

      expect(response).to have_http_status(:ok)
      expect(value("automation", project.id, "decisions")).to eq("1")
      expect(value("automation", project.id, "active")).to eq("2")
      expect(value("automation", project.id, "blocked")).to eq("1")
      expect(value("automation", project.id, "datasets")).to eq("1")
      expect(cell("automation", project.id, "decisions")["href"])
        .to eq(member_home_approvals_path(project: project.key))
      expect(body.at_css('[data-test="automation-overview-cards"]')).to be_nil
    end
  end

  describe "SEO" do
    let(:environment) { create(:environment, organization:) }

    before do
      project.environments << environment
      project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
    end

    it "counts sites, open and critical findings and pages checked per project" do
      site = create(:seo_site, project:, environment:)
      create(:seo_issue, site:, severity: :critical)
      create(:seo_issue, site:, severity: :low, check_key: "thin_content")
      create(:seo_issue, site:, severity: :high, check_key: "missing_title", status: :resolved)
      sign_in(owner)

      get member_seo_path

      expect(response).to have_http_status(:ok)
      expect(value("seo", project.id, "sites")).to eq("1")
      expect(value("seo", project.id, "issues")).to eq("2")
      expect(value("seo", project.id, "critical")).to eq("1")
      expect(value("seo", project.id, "pages")).to eq("3")
      expect(cell("seo", project.id, "issues")["href"])
        .to eq(member_monitoring_seo_index_path(project_id: [ project.id ]))
    end

    it "offers to add a site where the project can have one, and a dash where it cannot" do
      other = create(:project, organization:, name: "CLI Tooling")
      sign_in(owner)

      get member_seo_path

      expect(cell("seo", project.id, "sites")["data-state"]).to eq("off")
      expect(cell("seo", project.id, "sites")["href"]).to eq(new_member_monitoring_seo_site_path)
      expect(cell("seo", other.id, "sites")["data-state"]).to eq("na")
      expect(body.at_css('[data-test="seo-overview-no-sites"]')).to be_nil
    end
  end

  describe "Knowledge" do
    it "counts the pages, the decisions and the proposals to review per project" do
      create(:knowledge_page, project:)
      create(:knowledge_page, :decision, project:)
      create(:knowledge_page, project:, status: :in_review)
      sign_in(owner)

      get member_knowledge_root_path

      expect(response).to have_http_status(:ok)
      expect(value("knowledge", project.id, "pages")).to eq("2")
      expect(value("knowledge", project.id, "decisions")).to eq("1")
      expect(value("knowledge", project.id, "review")).to eq("1")
      expect(cell("knowledge", project.id, "pages")["href"])
        .to eq(member_knowledge_pages_path(project_id: [ project.id ]))
      expect(body.at_css('[data-test="knowledge-overview-card-review"]')).to be_nil
    end
  end

  describe "Vault" do
    it "counts the secrets, the open anomalies and the overdue rotations per project" do
      create(:secret_variable, project:)
      create(:secret_variable, project:, rotation_interval_days: 30, rotated_at: 60.days.ago)
      create(:secret_health_anomaly, project:)
      sign_in(owner)

      get member_vault_path

      expect(response).to have_http_status(:ok)
      expect(value("vault", project.id, "variables")).to eq("2")
      expect(value("vault", project.id, "anomalies")).to eq("1")
      expect(value("vault", project.id, "rotation")).to eq("1")
      expect(cell("vault", project.id, "variables")["href"]).to eq(member_project_secrets_path(project))
      expect(body.at_css('[data-test="vault-section-personal"]')).to be_nil
      expect(body.at_css('[data-test="vault-onboarding"]')).to be_present
    end
  end
end
