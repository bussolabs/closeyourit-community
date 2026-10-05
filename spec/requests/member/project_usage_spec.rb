# frozen_string_literal: true

require "rails_helper"

# CYRA-733 — la telemetria d'uso arrivava in tabella e la leggeva solo il terminale: dentro il
# prodotto non c'era nessun posto dove vedere quali funzioni vengono aperte davvero. Questa è quel
# posto, dentro il progetto che le funzioni le riceve.
RSpec.describe "Member::ProjectUsage (CYRA-733)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def seen(kind:, symbol:, environment: "production", hits: 1, at: 1.hour.ago)
    Usage::Symbol.create!(project:, environment:, kind:, symbol:, hits_count: hits,
                          first_seen_at: at - 1.day, last_seen_at: at)
  end

  describe "GET show" do
    it "elenca ciò che è stato visto, dal più recente" do
      seen(kind: "feature_view", symbol: "tickets", hits: 42, at: 10.minutes.ago)
      seen(kind: "route", symbol: "Member::TicketsController#index", at: 3.days.ago)
      sign_in(owner)

      get member_project_usage_path(project)

      expect(response).to have_http_status(:ok)
      righe = Nokogiri::HTML(response.body).css("[data-test='usage-row']")
      expect(righe.size).to eq(2)
      expect(righe.first.text).to include("42")
      expect(righe.last.text).to include("Member::TicketsController#index")
    end

    # La chiave `tickets` è un nome interno: chi legge deve trovare la stessa parola che vede nel
    # menu, altrimenti la pagina d'uso parla una lingua sua.
    it "una funzione di prodotto si legge col suo nome, non con la chiave" do
      seen(kind: "feature_view", symbol: "tickets")
      sign_in(owner)

      get member_project_usage_path(project)

      expect(response.body).to include(I18n.t("member.assistant.catalog.tickets.label"))
    end

    it "un simbolo senza nome nel catalogo resta leggibile com'è" do
      seen(kind: "feature_view", symbol: "una-chiave-di-un-altro-prodotto")
      sign_in(owner)

      get member_project_usage_path(project)

      expect(response.body).to include("una-chiave-di-un-altro-prodotto")
    end

    it "conta a parte le funzioni e le pagine" do
      seen(kind: "feature_view", symbol: "tickets")
      seen(kind: "feature_view", symbol: "projects")
      seen(kind: "route", symbol: "Member::TicketsController#index")
      sign_in(owner)

      get member_project_usage_path(project)

      conteggi = Nokogiri::HTML(response.body).css("[data-test='usage-counts']").text
      expect(conteggi).to include("3").and include("2").and include("1")
    end

    it "il filtro per tipo restringe l'elenco" do
      seen(kind: "feature_view", symbol: "tickets")
      seen(kind: "route", symbol: "Member::TicketsController#index")
      sign_in(owner)

      get member_project_usage_path(project), params: { kind: "feature_view" }

      righe = Nokogiri::HTML(response.body).css("[data-test='usage-row']")
      expect(righe.size).to eq(1)
      expect(righe.first.text).not_to include("Member::TicketsController#index")
    end

    it "il filtro per ambiente restringe l'elenco" do
      seen(kind: "feature_view", symbol: "tickets", environment: "production")
      seen(kind: "feature_view", symbol: "ideas", environment: "staging")
      sign_in(owner)

      get member_project_usage_path(project), params: { environment: "staging" }

      righe = Nokogiri::HTML(response.body).css("[data-test='usage-row']")
      expect(righe.size).to eq(1)
      expect(righe.first.text).to include(I18n.t("member.assistant.catalog.ideas.label"))
    end

    it "senza nessun segnale spiega che cosa manca, invece di una tabella vuota" do
      sign_in(owner)

      get member_project_usage_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.usage.empty"))
    end

    it "non mostra l'uso di un altro progetto" do
      altro = create(:project, organization: org)
      Usage::Symbol.create!(project: altro, environment: "production", kind: "feature_view",
                            symbol: "altrove", first_seen_at: 1.day.ago, last_seen_at: 1.hour.ago)
      seen(kind: "feature_view", symbol: "tickets")
      sign_in(owner)

      get member_project_usage_path(project)

      expect(response.body).not_to include("altrove")
    end

    # Anti-BOLA: il progetto di un'altra organizzazione non esiste, non «è vietato».
    it "il progetto di un'altra organizzazione non si apre" do
      estraneo = create(:project, organization: create(:organization))
      sign_in(owner)

      get member_project_usage_path(estraneo)

      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-924 — a register sorts on its dates only, in both directions.
  describe "sorting" do
    def table_text = Nokogiri::HTML(response.body).css("tbody").text

    before do
      sign_in(owner)
      seen(kind: "feature_view", symbol: "older_feature", at: 2.days.ago)
      seen(kind: "feature_view", symbol: "newer_feature", at: 1.hour.ago)
    end

    it "lists the least recently seen first when last seen is sorted ascending" do
      get member_project_usage_path(project, sort: "last_seen")

      expect(table_text.index("older_feature")).to be < table_text.index("newer_feature")
    end

    it "lists the first seen most recently first when first seen is sorted descending" do
      get member_project_usage_path(project, sort: "-first_seen")

      expect(table_text.index("newer_feature")).to be < table_text.index("older_feature")
    end

    it "offers the two dates as the only sortable columns" do
      get member_project_usage_path(project)

      sortable = Nokogiri::HTML(response.body).css("thead a[data-test^='sort-']").map { |a| a["data-test"] }
      expect(sortable).to eq(%w[sort-first_seen sort-last_seen])
    end
  end

  # CYRA-924 — the counts line above the list says how many there are; the bar holds no count (C63).
  it "keeps the count out of the bar" do
    sign_in(owner)
    seen(kind: "feature_view", symbol: "tickets")

    get member_project_usage_path(project)

    toolbar = Nokogiri::HTML(response.body).at_css("[data-test='usage-toolbar']")
    expect(toolbar.text).not_to include(I18n.t("member.usage.count", count: 1))
  end
end
