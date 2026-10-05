# frozen_string_literal: true

require "rails_helper"

# CYRA-344 — l'area prometteva log organizzati per campi e offriva solo una ricerca di testo dentro il
# messaggio: nessun elenco dei campi presenti, nessun filtro su uno di essi, e una colonna vuota su
# tutte le righe di tutte le pagine.
RSpec.describe "Member::Monitoring::LogEntries — campi (CYRA-344)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def log(data:, message: "voce", logger_name: nil)
    create(:log_entry, project: project, message: message, data: data, logger_name: logger_name)
  end

  it "elenca i campi presenti nel risultato coi valori più frequenti e quante volte compaiono" do
    allow_n_plus_one do
      2.times { log(data: { "action" => "checkout" }) }
      log(data: { "action" => "login" })
    end

    get member_monitoring_log_entries_path

    doc = Nokogiri::HTML(response.body)
    facet = doc.at_css("[data-test='logs-facet-action']")
    expect(facet).to be_present
    expect(facet.text).to include("checkout").and include("2")
    expect(facet.text).to include("login")
  end

  it "cliccando un valore il risultato si restringe e il filtro resta visibile e removibile" do
    allow_n_plus_one do
      log(data: { "action" => "checkout" }, message: "riga del checkout")
      log(data: { "action" => "login" }, message: "riga del login")
    end

    get member_monitoring_log_entries_path(field: "action", value: "checkout")

    expect(response.body).to include("riga del checkout")
    expect(response.body).not_to include("riga del login")
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='logs-field-filter']").text).to include("checkout")
    expect(doc.at_css("[data-test='logs-field-filter-remove']")).to be_present
  end

  it "la colonna senza un solo valore nel risultato non viene mostrata" do
    log(data: {}, message: "senza logger")

    get member_monitoring_log_entries_path

    expect(response.body).not_to include(I18n.t("member.monitoring.logs.col_logger"))
  end

  it "la colonna compare quando almeno una riga ha il valore" do
    log(data: {}, message: "con logger", logger_name: "sidekiq")

    get member_monitoring_log_entries_path

    expect(response.body).to include(I18n.t("member.monitoring.logs.col_logger"))
    expect(response.body).to include("sidekiq")
  end

  it "sotto la ricerca c'è scritto cosa cerca" do
    log(data: {})

    get member_monitoring_log_entries_path

    expect(Nokogiri::HTML(response.body).at_css("[data-test='logs-search-hint']").text)
      .to include(I18n.t("member.monitoring.logs.search_hint"))
  end
end
