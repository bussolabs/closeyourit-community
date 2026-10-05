# frozen_string_literal: true

require "rails_helper"

# rack_test (no JS): copre le interazioni a form pieno (banner, elimina step) e il rendering della
# timeline e del picker di ungroup. I flussi con dialog Stimulus — bulk "seleziona → raggruppa" e
# "ungroup → scegli la finestra che tiene lo status" — sono coperti dai request spec + browser reale.
RSpec.describe "Member — Uptime incidents & banner", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:owner) { create(:account) }
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
  let(:monitor) { create(:uptime_monitor, project:, environment:) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(who)
    visit login_path
    fill_test "login-email", with: who.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "il manager crea il banner di manutenzione e ne vede l'anteprima" do
    sign_in_as(owner)
    visit member_monitoring_monitor_path(monitor, tab: "public")

    find("[data-test='announcement-level']").select(I18n.t("member.uptime.announcement.levels.maintenance"))
    fill_test "announcement-message", with: "Manutenzione notturna 2-4"
    click_on_test "announcement-save"

    expect_test "announcement-preview"
    expect(page).to have_css("[data-test='status-announcement'][data-level='maintenance']")
    expect(page).to have_text("Manutenzione notturna 2-4")
    expect(monitor.reload.announcement.message).to eq("Manutenzione notturna 2-4")
  end

  it "mostra la timeline di un incident narrato con gli step" do
    inc = create(:uptime_incident, monitor:, phase: :monitoring, started_at: 20.minutes.ago, resolved_at: nil)
    create(:uptime_incident_update, incident: inc, phase: :detected, body: "Rilevato problema al DNS")
    sign_in_as(owner)
    visit member_monitoring_monitor_path(monitor)

    expect_test "incident-timeline"
    expect(page).to have_text("Rilevato problema al DNS")
  end

  it "il picker di ungroup elenca una finestra per riga, default sul primary che tiene lo status" do
    primary = create(:uptime_incident, :narrated, monitor:, started_at: 2.hours.ago)
    create(:uptime_incident, monitor:, parent: primary, started_at: 90.minutes.ago)
    sign_in_as(owner)
    visit member_monitoring_monitor_path(monitor)

    expect(page).to have_css("[data-test='incident-ungroup-dialog']", visible: :all)
    expect(page).to have_css("[data-test='incident-ungroup-window']", count: 2, visible: :all)
    expect(page).to have_css("input[name='keep_incident_id'][value='#{primary.id}'][checked]", visible: :all)
  end

  it "elimina uno step della timeline (button_to, senza JS)" do
    inc = create(:uptime_incident, :narrated, monitor:, resolved_at: nil)
    create(:uptime_incident_update, incident: inc, phase: :detected, body: "Da rimuovere")
    sign_in_as(owner)
    visit member_monitoring_monitor_path(monitor)

    expect do
      click_on_test "incident-update-delete"
    end.to change(Uptime::IncidentUpdate, :count).by(-1)
  end

  it "elimina un incident intero dal modale di gestione (button_to, senza JS)" do
    inc = create(:uptime_incident, :narrated, monitor:, resolved_at: nil)
    sign_in_as(owner)
    visit member_monitoring_monitor_path(monitor)

    expect do
      click_on_test "incident-delete-#{inc.id}"
    end.to change(Uptime::Incident, :count).by(-1)
    expect(page).to have_current_path(member_monitoring_monitor_path(monitor))
  end
end
