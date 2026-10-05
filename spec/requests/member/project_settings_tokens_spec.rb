# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the ingest tokens live in the project Settings page, next to the other ways data reaches
# the project. The old tokens address still works: it forwards to the section.
RSpec.describe "Member::ProjectSettings tokens section", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def issue(name, **attributes)
    token = Projects::Tokens::Issue.call(project:, name:, host: "x", environment:).value[:token]
    token.update_columns(attributes) if attributes.any?
    token
  end

  # A member who can manage tokens but cannot edit the project: the default Maintainer role.
  def token_manager
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    create(:project_membership, account: account, project: project)
    role = create(:role, organization: org)
    create(:role_permission, role: role, permission_key: "tokens.manage")
    create(:account_role, account: account, role: role, organization: org)
    account
  end

  describe "GET settings" do
    it "shows the tokens section before the settings forms" do
      sign_in(owner)
      get member_project_settings_path(project)

      sections = doc.css("[data-test='project-settings-tokens'], [data-test^='project-settings-form-']")
      expect(sections.map { |node| node["data-test"] }.first(2)).to eq(%w[project-settings-tokens project-settings-form-ingest])
    end

    it "always shows the project ID with a copy button" do
      sign_in(owner)
      get member_project_settings_path(project)

      row = doc.at_css("[data-test='project-id']")
      expect(row.text).to include(project.id)
      expect(row.at_css("[data-action='clipboard#copy']")).to be_present
    end

    it "folds the tooltip text into the section subtitle, with no info icon" do
      sign_in(owner)
      get member_project_settings_path(project)

      section = doc.at_css("[data-test='project-settings-tokens']")
      expect(section.text).to include(I18n.t("member.tokens.help_ingest"))
      expect(section.at_css("[data-test='help-ingest-token']")).to be_nil
    end

    it "keeps the new token form behind a closed disclosure" do
      environment
      sign_in(owner)
      get member_project_settings_path(project)

      disclosure = doc.at_css("details[data-test='token-form-disclosure']")
      expect(disclosure).to be_present
      expect(disclosure["open"]).to be_nil
      expect(disclosure.at_css("summary").text).to include(I18n.t("member.tokens.form.title"))
      expect(disclosure.at_css("[data-test='token-form']")).to be_present
    end

    it "counts the tokens by state" do
      sign_in(owner)
      issue("Active")
      issue("Due soon", expires_at: 3.days.from_now)
      issue("Expired", expires_at: 1.day.ago)
      issue("Revoked", revoked_at: 1.hour.ago)

      get member_project_settings_path(project)

      counts = doc.at_css("[data-test='tokens-counts']")
      value = ->(test) { counts.at_css("[data-test='#{test}']").text.gsub(/\D/, "") }
      expect(value.call("tokens-count-total")).to eq("4")
      expect(value.call("tokens-count-active")).to eq("2")
      expect(value.call("tokens-count-due-soon")).to eq("1")
      expect(value.call("tokens-count-expired")).to eq("1")
      expect(value.call("tokens-count-revoked")).to eq("1")
    end

    it "searches the tokens by name" do
      sign_in(owner)
      issue("Production SDK")
      issue("CI staging")

      get member_project_settings_path(project), params: { q: "sdk" }

      expect(doc.at_css("[data-test='tokens-toolbar']")).to be_present
      rows = doc.css("[data-test='token-row']")
      expect(rows.map { |row| row.text.squish }).to contain_exactly(a_string_including("Production SDK"))
    end

    # CYRA-924 — the counts line above the list says how many there are; the bar holds no count (C63).
    it "keeps the count out of the bar" do
      sign_in(owner)
      issue("Production SDK")

      get member_project_settings_path(project)

      expect(doc.at_css("[data-test='tokens-toolbar']").text).not_to include(I18n.t("member.tokens.count", count: 1))
    end

    it "filters the tokens by state" do
      sign_in(owner)
      issue("Still good")
      issue("Gone", revoked_at: 1.hour.ago)
      issue("Too old", expires_at: 1.day.ago)

      get member_project_settings_path(project), params: { status: %w[revoked expired] }

      names = doc.css("[data-test='token-row']").map { |row| row.text.squish }
      expect(names).to contain_exactly(a_string_including("Gone"), a_string_including("Too old"))
    end

    it "shows the expired state and date" do
      sign_in(owner)
      create(:project_token, :expired, project: project, environment: environment)

      get member_project_settings_path(project)

      expect(response.body).to include('data-test="token-expiry"')
      expect(response.body).to include(I18n.t("member.tokens.status_expired"))
      expect(response.body).to include(Ui::BadgeComponent::COLORS.fetch(:red)[:box])
    end

    it "paginates the tokens" do
      sign_in(owner)
      (App::Constants::TABLE_PER_PAGE + 1).times { |i| issue("Token #{i}") }

      get member_project_settings_path(project), params: { page: 1 }
      expect(doc.css("[data-test='token-row']").size).to eq(App::Constants::TABLE_PER_PAGE)
      expect(response.body).to include('data-test="tokens-pagination"')

      get member_project_settings_path(project), params: { page: 2 }
      expect(doc.css("[data-test='token-row']").size).to eq(1)
    end

    it "lists every section in the side index, linked to its anchor" do
      sign_in(owner)
      get member_project_settings_path(project)

      links = doc.css("[data-test='project-settings-nav'] a").map { |a| a["href"] }
      expect(links).to eq(%w[#tokens #ingest #tickets #retention #thresholds #features #danger])
      links.each { |anchor| expect(doc.at_css(anchor)).to be_present }
    end

    it "puts public ingest first among the forms, then tickets, then retention" do
      sign_in(owner)
      get member_project_settings_path(project)

      order = doc.css("[data-test^='project-settings-form-'] [data-test$='-section']").map { |node| node["data-test"] }
      expect(order).to eq(%w[project-ingest-section project-default-assignee-section
                             project-retention-section project-thresholds-section])
    end

    it "says the inherit rule once for the retention fields and keeps each effective value" do
      sign_in(owner)
      get member_project_settings_path(project)

      section = doc.at_css("[data-test='project-retention-section']")
      expect(section.text.scan(I18n.t("member.project_settings.retention_hint")).size).to eq(1)
      %w[project-settings-effective project-settings-analytics-effective project-settings-errors-effective
         project-settings-performance-effective project-settings-uptime-effective].each do |test|
        expect(section.at_css("[data-test='#{test}']")).to be_present
      end
    end

    it "translates the project CTO field" do
      owner.update!(locale: "en")
      sign_in(owner)
      get member_project_settings_path(project)

      section = doc.at_css("[data-test='project-default-assignee-section']")
      expect(section.text).to include(I18n.t("member.project_settings.cto_label", locale: :en))
      expect(section.text).to include(I18n.t("member.project_settings.cto_hint", locale: :en))
      expect(section.text).not_to include("CTO del progetto")
    end

    it "shows no 'applies instantly' note beside each switch" do
      sign_in(owner)
      get member_project_settings_path(project)

      statuses = doc.css("[data-test='project-features'] [data-ui--switch-target='status']")
      expect(statuses).not_to be_empty
      expect(statuses.map { |node| node.text.strip }.uniq).to eq([ "" ])
    end

    it "no longer lists the tokens page in the More menu" do
      sign_in(owner)
      get member_project_settings_path(project)

      expect(doc.at_css("[data-test='project-tokens-link']")).to be_nil
      expect(doc.at_css("[data-test='project-settings-link']")).to be_present
    end
  end

  describe "a member who manages tokens but cannot edit the project" do
    it "sees Settings with the tokens section only" do
      sign_in(token_manager)
      get member_project_settings_path(project)

      expect(response).to have_http_status(:ok)
      expect(doc.at_css("[data-test='project-settings-tokens']")).to be_present
      expect(doc.at_css("[data-test^='project-settings-form-']")).to be_nil
      expect(doc.at_css("[data-test='project-features']")).to be_nil
      expect(doc.css("[data-test='project-settings-nav'] a").map { |a| a["href"] }).to eq(%w[#tokens])
      expect(doc.at_css("[data-test='project-settings-link']")).to be_present
    end

    it "still cannot change the settings" do
      sign_in(token_manager)
      patch member_project_settings_path(project), params: { logs_retention_days: 9 }

      expect(response).to redirect_to(root_path)
      expect(project.reload.logs_retention_days).to be_nil
    end
  end

  it "a member with neither permission is turned away" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    sign_in(member)

    get member_project_settings_path(project)

    expect(response).to redirect_to(root_path)
  end
end
