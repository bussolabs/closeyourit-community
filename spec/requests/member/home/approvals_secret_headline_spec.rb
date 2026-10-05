# frozen_string_literal: true

require "rails_helper"

# CYRA-884 — a secret change reads as one sentence, and in production it says what breaks.
RSpec.describe "Member::Home::Approvals secret change headline", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def change_in(code, label, **attributes)
    environment = create(:environment, organization: org, code:, label:)
    create(:secret_change_request, organization: org, project:, environment:, name: "PAYMENT_KEY",
                                   requested_by: create(:account), **attributes)
  end

  def page = Nokogiri::HTML(response.body)

  it "names the change in one sentence and marks production as high risk" do
    request = change_in("production", "Production")
    sign_in(owner)

    get member_home_approvals_item_path(kind: "secret_change", id: request.id)

    expect(page.at_css("[data-test='approvals-secret-headline']").text)
      .to include(I18n.t("member.approvals.secret.headline.set", name: "PAYMENT_KEY", environment: "Production"))
    expect(page.at_css("[data-test='approvals-secret-risk']").text)
      .to include(I18n.t("member.approvals.secret.production_risk.set"))
  end

  it "uses the removal sentence for a removal" do
    request = change_in("production", "Production", action: "remove", value: nil)
    sign_in(owner)

    get member_home_approvals_item_path(kind: "secret_change", id: request.id)

    expect(page.at_css("[data-test='approvals-secret-headline']").text)
      .to include(I18n.t("member.approvals.secret.headline.remove", name: "PAYMENT_KEY", environment: "Production"))
  end

  it "shows no risk line outside production" do
    request = change_in("staging", "Staging")
    sign_in(owner)

    get member_home_approvals_item_path(kind: "secret_change", id: request.id)

    expect(page.at_css("[data-test='approvals-secret-headline']")).to be_present
    expect(page.at_css("[data-test='approvals-secret-risk']")).to be_nil
  end
end
