# frozen_string_literal: true

require "rails_helper"

# CYRA-940 — the Help desk tab of a project: the requests written from that project's sites.
RSpec.describe "Member::ProjectHelpdeskRequests", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Shop", helpdesk_enabled: true) }
  let(:owner) { account_with_membership(:owner) }
  # Sees the project, without the key.
  let(:colleague) { account_with_membership(:member, on_project: true) }

  def account_with_membership(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role:)
      create(:project_membership, account:, project:) if on_project
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def request_for(*traits, on: project, **attributes)
    create(:helpdesk_request, *traits, project: on, **attributes)
  end

  def document = Nokogiri::HTML(response.body)

  it "lists the new requests of this project only, without the project column" do
    request_for(body: "I cannot pay by card 5001", email: "anna@example.com")
    request_for(on: create(:project, organization: org, name: "Portal", helpdesk_enabled: true), body: "Other project 5002")
    sign_in(owner)

    get member_project_helpdesk_requests_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("I cannot pay by card 5001", "anna@example.com")
    expect(response.body).not_to include("Other project 5002")
    expect(document.css('[data-test="project-helpdesk-table"] th').map(&:text).join).not_to include(I18n.t("member.helpdesk.col_project"))
    expect(document.at_css('[data-test="project-helpdesk-count"]').text).to include("1")
  end

  it "keeps discarded requests one filter away and searches the text" do
    request_for(:discarded, body: "Buy followers 5003")
    request_for(body: "Card payment fails 5004")
    request_for(body: "Password question 5005")
    sign_in(owner)

    get member_project_helpdesk_requests_path(project)
    expect(response.body).not_to include("Buy followers 5003")

    get member_project_helpdesk_requests_path(project, status: [ "discarded" ])
    expect(response.body).to include("Buy followers 5003")

    get member_project_helpdesk_requests_path(project, status: [ "received" ], q: "payment")
    expect(response.body).to include("Card payment fails 5004")
    expect(response.body).not_to include("Password question 5005")
  end

  it "shows the tab on the project pages to whoever holds the key, active on this page" do
    sign_in(owner)

    get member_project_helpdesk_requests_path(project)

    tab = document.at_css('[data-test="project-helpdesk-link"]')
    expect(tab["href"]).to eq(member_project_helpdesk_requests_path(project))
    expect(tab["aria-current"]).to eq("page")
  end

  it "hides the tab and refuses the page without helpdesk.manage on the project" do
    sign_in(colleague)

    get member_project_path(project)
    expect(response.body).not_to include('data-test="project-helpdesk-link"')

    get member_project_helpdesk_requests_path(project)
    expect(response).not_to have_http_status(:ok)
  end

  it "answers 404 for a project of another organization" do
    foreign = create(:project, organization: create(:organization))
    sign_in(owner)

    get member_project_helpdesk_requests_path(foreign)

    expect(response).to have_http_status(:not_found)
  end

  it "hides the tab on a project that does not receive requests" do
    project.update!(helpdesk_enabled: false)
    sign_in(owner)

    get member_project_path(project)

    expect(response.body).not_to include('data-test="project-helpdesk-link"')
  end

  describe "the Connect the site panel" do
    let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
    let(:public_key) { Projects::Tokens::Issue.call(project:, name: "Site", host: "shop.example.com", environment:).value[:token].public_key }
    # Holds helpdesk.manage and nothing else: reads the requests, not the project keys.
    let(:agent) do
      account_with_membership(:member, on_project: true).tap do |account|
        create(:account_permission, account:, organization: org, permission_key: "helpdesk.manage", effect: :allow)
      end
    end

    def panel = document.at_css('[data-test="project-helpdesk-connect"]')

    it "is open with the project's own address and key while no request has arrived" do
      public_key
      sign_in(owner)

      get member_project_helpdesk_requests_path(project)

      expect(panel["open"]).to be_present
      snippet = panel.at_css('[data-test="project-helpdesk-snippet"]').text
      expect(snippet).to include("/api/v1/projects/#{project.id}/helpdesk_requests", "sentry_key=#{public_key}",
                                 %(name="#{Helpdesk::Constants::HONEYPOT_FIELD}"))
      prompt = panel.at_css('[data-test="project-helpdesk-prompt"]').text
      expect(prompt).to include("/api/v1/projects/#{project.id}/helpdesk_requests", public_key, "202", "422", "429")
      expect(panel.css('[data-action="clipboard#copy"]').size).to eq(2)
    end

    it "starts closed once requests are there" do
      request_for(body: "First request 5010")
      sign_in(owner)

      get member_project_helpdesk_requests_path(project)

      expect(panel).to be_present
      expect(panel["open"]).to be_nil
    end

    it "keeps the key out of the page for whoever does not manage the project keys" do
      public_key
      sign_in(agent)

      get member_project_helpdesk_requests_path(project)

      expect(response.body).not_to include(public_key)
      expect(panel.at_css('[data-test="project-helpdesk-key-locked"]')).to be_present
      expect(panel.text).to include(I18n.t("member.monitoring.analytics.onboarding.key_placeholder"))
    end

    it "is not shown on a project that is off" do
      project.update!(helpdesk_enabled: false)
      sign_in(owner)

      get member_project_helpdesk_requests_path(project)

      expect(panel).to be_nil
    end
  end

  it "says the help desk is off, and where the switch is, on a project that is off" do
    project.update!(helpdesk_enabled: false)
    sign_in(owner)

    get member_project_helpdesk_requests_path(project)

    empty = document.at_css('[data-test="project-helpdesk-empty"]')
    expect(empty.text).to include(I18n.t("member.helpdesk.project.empty_off_title"))
    expect(empty.at_css('[data-test="project-helpdesk-settings"]')["href"]).to eq(member_project_settings_path(project))
  end

  # Before the first request the site is not connected: "no requests" would read as an inbox at work.
  it "shows how to connect the site, and no empty state, until a first request arrives" do
    sign_in(owner)

    get member_project_helpdesk_requests_path(project)

    expect(response.body).not_to include('data-test="project-helpdesk-empty"', I18n.t("member.helpdesk.empty"))
    expect(document.at_css('[data-test="project-helpdesk-connect"]')["open"]).to be_present
  end

  it "offers the form and the prompt as two ways of the same step" do
    sign_in(owner)

    get member_project_helpdesk_requests_path(project)

    steps = document.css('[data-test="project-helpdesk-connect"] [data-test^="project-helpdesk-step-"]')
    expect(steps.map { |step| step["data-test"] }).to eq(%w[project-helpdesk-step-2a project-helpdesk-step-2b])
    expect(steps.first.parent).to eq(steps.last.parent)
  end
end
