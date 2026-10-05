# frozen_string_literal: true

require "rails_helper"

# Il pulsante "Incorpora" apre un <dialog> nativo via lo Stimulus condiviso `ui--dialog`: serve un
# browser vero perché `showModal()` esiste solo lì (con rack_test il markup c'è ma il dialog resta
# chiuso). Gating js condiviso in `spec/support/js_system.rb`; opt-in con JS_SYSTEM_SPECS=1.
RSpec.describe "Member — incorporare la status page nel proprio sito", :js, type: :system do
  let(:org) { create(:organization, name: "Demo", slug: "demo") }
  let(:owner) do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end
  let(:project) do
    create(:project, organization: org, key: "MYAP", name: "My App").tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) do
    create(:environment, organization: org, code: "production", label: "Production").tap { |e| project.environments << e }
  end

  it "apre gli snippet dalla pagina di un monitor pubblicato e mostra l'anteprima del riquadro" do
    monitor = create(:uptime_monitor, project:, environment:, public_status_enabled: true, current_status: :up)

    sign_in_as(owner)
    visit member_monitoring_monitor_path(monitor)
    find("[data-test='monitor-tab-public']").click

    expect(page).to have_no_css("[data-test='monitor-embed-dialog'][open]")
    find("[data-test='monitor-embed']").click

    dialog = find("[data-test='monitor-embed-dialog'][open]")
    expect(dialog).to have_css("[data-test='monitor-embed-badge']")
    expect(dialog).to have_css("[data-test='monitor-embed-page']")
    expect(dialog.text).to include(I18n.t("member.uptime.embed_title"))

    # L'anteprima è l'iframe del badge vero: se il badge non rispondesse, qui non ci sarebbe nulla.
    badge_frame = dialog.find("iframe[src*='/badge']")
    within_frame(badge_frame) do
      expect(page).to have_css("[data-test='status-badge'][data-state='operational']")
    end
  end

  it "il pulsante non c'è finché la status page non è pubblicata" do
    monitor = create(:uptime_monitor, project:, environment:, public_status_enabled: false)

    sign_in_as(owner)
    visit member_monitoring_monitor_path(monitor, tab: "public")

    expect(page).to have_no_css("[data-test='monitor-embed']")
  end
end
