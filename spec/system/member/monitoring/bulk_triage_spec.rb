# frozen_string_literal: true

require "rails_helper"

# CYRA-45: selezione multipla + triage in un colpo dalla lista (errori e metriche). Il form del bulk è
# progressive enhancement (funziona senza JS): la barra azioni è `[hidden]` finché ui--bulk-select non la
# mostra, quindi qui (rack_test, no JS) i bottoni si raggiungono con visible: :all e si assertisce il DB.
RSpec.describe "Member monitoring — triage bulk dalla lista", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner_account
    account = create(:account)
    create(:membership, account:, organization: org, role: :owner)
    account
  end

  before { Types::InstallDefaults.call(organization: org) }

  it "errori: seleziona due gruppi e li risolve in un colpo" do
    a = create(:error_group, project:, status: :unresolved, title: "RuntimeError: A")
    b = create(:error_group, project:, status: :unresolved, title: "RuntimeError: B")
    sign_in_as(owner_account)

    visit member_monitoring_error_groups_path
    find("[data-test='error-select-#{a.id}']", visible: :all).set(true)
    find("[data-test='error-select-#{b.id}']", visible: :all).set(true)
    find("[data-test='errors-bulk-resolve']", visible: :all).click

    expect(a.reload).to be_status_resolved
    expect(b.reload).to be_status_resolved
  end

  it "errori: ignora un solo gruppo dalla lista" do
    a = create(:error_group, project:, status: :unresolved, title: "RuntimeError: Solo")
    sign_in_as(owner_account)

    visit member_monitoring_error_groups_path
    find("[data-test='error-select-#{a.id}']", visible: :all).set(true)
    find("[data-test='errors-bulk-ignore']", visible: :all).click

    expect(a.reload).to be_status_ignored
  end

  it "metriche: seleziona un gruppo e lo ignora in un colpo" do
    g = create(:metric_group, project:, status: :unresolved)
    sign_in_as(owner_account)

    visit member_monitoring_metric_groups_path
    find("[data-test='metric-select-#{g.id}']", visible: :all).set(true)
    find("[data-test='metrics-bulk-ignore']", visible: :all).click

    expect(g.reload).to be_status_ignored
  end

  it "metriche: la lista mostra il badge di stato dopo il triage" do
    g = create(:metric_group, project:, status: :resolved, title: "SELECT slow")
    sign_in_as(owner_account)

    visit member_monitoring_metric_groups_path
    within("##{ActionView::RecordIdentifier.dom_id(g)}") do
      expect(page).to have_text(I18n.t("member.metrics.status.resolved"))
    end
  end
end
