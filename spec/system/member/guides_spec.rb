require "rails_helper"

RSpec.describe "Member guides", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:account) { create(:account) }

  before { create(:membership, account: account, organization: org, role: :member) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "opens the guides index from the footer button" do
    sign_in_as(account)
    visit member_projects_path

    click_on_test "footer-guides"

    expect(page).to have_current_path(member_guides_path)
    expect_test "member-guides-index"
  end

  it "l'indice mostra tre card che aprono i dettagli" do
    sign_in_as(account)
    visit member_guides_path

    expect_test "member-guides-card-errors"
    expect_test "member-guides-card-uptime"
    expect_test "member-guides-card-performance"

    click_on_test "member-guides-card-errors"
    expect_test "member-guide-errors"

    visit member_guides_path
    click_on_test "member-guides-card-uptime"
    expect_test "member-guide-uptime"

    visit member_guides_path
    click_on_test "member-guides-card-performance"
    expect_test "member-guide-performance"
  end

  it "ogni dettaglio espone la propria CTA" do
    sign_in_as(account)

    visit member_guides_errors_path
    expect_test "member-guide-errors-cta"

    visit member_guides_uptime_path
    expect_test "member-guide-uptime-cta"

    visit member_guides_performance_path
    expect_test "member-guide-performance-cta"
  end

  it "le CTA puntano a route reali, mai a un dead link" do
    sign_in_as(account)

    visit member_guides_errors_path
    expect(find("[data-test='member-guide-errors-cta']")[:href]).to eq(member_monitoring_error_groups_path)

    visit member_guides_uptime_path
    expect(find("[data-test='member-guide-uptime-cta']")[:href]).to eq(member_monitoring_monitors_path)

    visit member_guides_performance_path
    expect(find("[data-test='member-guide-performance-cta']")[:href]).to eq(member_monitoring_metric_groups_path)
  end
end
