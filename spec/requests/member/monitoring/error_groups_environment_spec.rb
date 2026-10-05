# frozen_string_literal: true

require "rails_helper"

# CYRA-375 — nell'elenco degli errori le segnalazioni della prova e quelle del sito vero erano
# mescolate e niente sulla riga diceva da dove venissero: il gruppo più voluminoso della prima pagina
# era staging, quindi chi apriva la pagina in emergenza partiva dalla riga sbagliata.
RSpec.describe "Member::Monitoring::ErrorGroups — ambiente (CYRA-375)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def group_with_event(title:, environment:, events: 1, occurred_at: 1.hour.ago)
    group = create(:error_group, project: project, title: title, events_count: events)
    allow_n_plus_one do
      create(:error_event, group: group, project: project, environment: environment, occurred_at: occurred_at)
    end
    group
  end

  it "keeps every events subquery inside the visible projects (CYRA-893)" do
    group_with_event(title: "Boom", environment: "production")
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] if payload[:sql].include?('FROM "errors_events"') }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get member_monitoring_error_groups_path
      get member_monitoring_error_groups_path, params: { environment: [ "production" ] }
    end

    event_scans = sql.flat_map { |q| q.scan(/FROM "errors_events" WHERE (.*?)(?:\)|ORDER|$)/).flatten }
    expect(event_scans).not_to be_empty
    expect(event_scans).to all(match(/"errors_events"\."(project_id|group_id)"/))
  end

  it "ogni riga mostra l'ambiente dell'ultima occorrenza" do
    group_with_event(title: "Boom in produzione", environment: "production")

    get member_monitoring_error_groups_path

    badge = Nokogiri::HTML(response.body).at_css("[data-test='error-group-environment']")
    expect(badge).to be_present
    expect(badge.text.strip).to eq("production")
  end

  it "senza filtri si atterra sui non risolti del sito vero" do
    prod = group_with_event(title: "Errore vero", environment: "production")
    staging = group_with_event(title: "Errore di prova", environment: "staging", events: 2202)

    get member_monitoring_error_groups_path

    expect(response.body).to include(prod.title)
    expect(response.body).not_to include(staging.title)
  end

  it "il filtro per ambiente resta nell'indirizzo e seleziona i gruppi che l'hanno toccato" do
    prod = group_with_event(title: "Errore vero", environment: "production")
    staging = group_with_event(title: "Errore di prova", environment: "staging")

    get member_monitoring_error_groups_path(environment: [ "staging" ])

    expect(response.body).to include(staging.title)
    expect(response.body).not_to include(prod.title)
  end

  it "chiedendo tutti gli ambienti il default non si intromette" do
    prod = group_with_event(title: "Errore vero", environment: "production")
    staging = group_with_event(title: "Errore di prova", environment: "staging")

    get member_monitoring_error_groups_path(environment: [ "production", "staging" ])

    expect(response.body).to include(prod.title)
    expect(response.body).to include(staging.title)
  end
  it "un gruppo di cui non si conosce l'ambiente resta in vista: il default non fa sparire errori veri" do
    senza_ambiente = create(:error_group, project: project, title: "Errore senza ambiente")
    group_with_event(title: "Errore di prova", environment: "staging")

    get member_monitoring_error_groups_path

    expect(response.body).to include(senza_ambiente.title)
  end
end
