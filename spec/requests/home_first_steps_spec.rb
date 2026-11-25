# frozen_string_literal: true

require "rails_helper"

# CYRA-1159 — the first-steps list above the decision of the day, and its closing for everyone.
RSpec.describe "Home first steps", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)
  def step(name) = html.at_css("[data-test='home-first-step-#{name}']")

  it "shows the five steps to do to the owner of a new organization, with the way to close it" do
    sign_in(owner)

    get root_path

    expect(html.at_css("[data-test='home-first-steps']")).to be_present
    expect(html.css("[data-test^='home-first-step-'][data-done='false']").size).to eq(5)
    expect(step("alert-rule").at_css("a")["href"]).to eq(new_member_alerting_rule_path)
    expect(html.at_css("[data-test='home-first-steps-dismiss']")).to be_present
  end

  it "ticks the first error and still shows the missing steps" do
    Organizations::FirstStep.record!(:first_error, organization_ids: org.id)
    sign_in(member)

    get root_path

    expect(step("first-error")["data-done"]).to eq("true")
    expect(step("telegram")["data-done"]).to eq("false")
    expect(html.at_css("[data-test='home-first-steps-dismiss']")).to be_nil
  end

  it "is gone once the five steps are done" do
    Organizations::FirstStep::STEPS.each { |name| Organizations::FirstStep.record!(name, organization_ids: org.id) }
    sign_in(owner)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(html.at_css("[data-test='home-first-steps']")).to be_nil
  end

  describe "closing the list" do
    it "the owner closes it for the whole organization" do
      sign_in(owner)
      get root_path
      dismiss = html.at_css("[data-test='home-first-steps-dismiss']").ancestors("form").first["action"]

      post dismiss

      expect(response).to redirect_to(root_path)
      expect(org.reload.first_steps_dismissed_at).to be_present

      delete logout_path
      sign_in(member)
      get root_path
      expect(html.at_css("[data-test='home-first-steps']")).to be_nil
    end

    it "a member cannot close it" do
      sign_in(member)

      post member_home_first_steps_dismissal_path(organization_id: org.id)

      expect(response).to redirect_to(root_path)
      expect(org.reload.first_steps_dismissed_at).to be_nil
    end

    it "closes only the organization the button was drawn for, never the one the session moved to" do
      other = create(:organization)
      create(:membership, account: owner, organization: other, role: :owner)
      sign_in(owner)
      post(member_organization_switches_path, params: { organization_id: other.id })

      post member_home_first_steps_dismissal_path(organization_id: org.id)

      expect(response).to redirect_to(root_path)
      expect(other.reload.first_steps_dismissed_at).to be_nil
      expect(org.reload.first_steps_dismissed_at).to be_nil
    end
  end
end
