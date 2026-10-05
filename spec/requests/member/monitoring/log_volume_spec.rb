# frozen_string_literal: true

require "rails_helper"

# CYRA-354 — sopra l'elenco c'erano tre numeri e poi subito la tabella: per scoprire cos'era successo
# alle tre di notte servivano cinquemila pagine da sfogliare. E quei numeri restavano identici anche
# filtrando, facendo credere che il filtro non avesse avuto effetto.
RSpec.describe "Member — volume dei log nel tempo", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  it "sopra l'elenco c'è il grafico del volume" do
    sign_in(owner)
    create(:log_entry, project:, occurred_at: 2.hours.ago)

    get member_monitoring_log_entries_path

    expect(body.at_css("[data-test='logs-volume-chart']")).to be_present
    expect(body.at_css("[data-test='logs-volume-buckets']")).to be_present
  end

  # F074 — the chart had bars and no axes: the peak and the hours were only in the tooltip.
  it "puts a value scale and the times on the chart" do
    sign_in(owner)
    create_list(:log_entry, 4, project:, occurred_at: 2.hours.ago)

    get member_monitoring_log_entries_path

    chart = body.at_css("[data-test='logs-volume-chart']")
    scale = chart.css("span.right-0.leading-none").map { |tick| tick.text.strip }
    times = chart.css("div.h-3\\.5 span").map { |tick| tick.text.strip }
    expect(scale).to include("4")
    expect(times.size).to be >= 2
    expect(times).to all(match(/\A\d{2}[:\/]\d{2}\z/))
  end

  # CYRA-570 — su un periodo senza un solo messaggio il grafico disegnava quarantotto barrette tutte
  # della stessa altezza minima: un quarto della finestra occupato per far credere che di messaggi ce
  # ne fossero pochissimi. Adesso lo dice, in una riga.
  it "senza messaggi nel periodo il grafico lo dichiara, invece di disegnare blocchi vuoti" do
    sign_in(owner)
    create(:log_entry, project:, occurred_at: 20.days.ago)

    get member_monitoring_log_entries_path

    expect(body.at_css("[data-test='logs-volume-buckets']")).to be_nil
    vuoto = body.at_css("[data-test='logs-volume-buckets-empty']")
    expect(vuoto).to be_present
    expect(vuoto.text).to include(I18n.t("member.monitoring.logs.chart_empty"))
  end

  # The chart counts the same messages as the list under it: filtered on one project, the others'
  # messages stay out; without a filter it sums every visible project.
  it "follows the project filter instead of mixing every project's messages" do
    quiet = create(:project, organization:)
    create(:log_entry, project:, occurred_at: 2.hours.ago)
    sign_in(owner)

    get member_monitoring_log_entries_path(project_id: [ quiet.id ])
    expect(body.at_css("[data-test='logs-volume-buckets']")).to be_nil
    expect(body.at_css("[data-test='logs-volume-buckets-empty']")).to be_present

    # `ft` = filters chosen on purpose (none): the page otherwise brings back the remembered project.
    get member_monitoring_log_entries_path(ft: 1)
    expect(body.at_css("[data-test='logs-volume-buckets']")).to be_present
  end

  it "un blocco con messaggi porta alla finestra di quel momento" do
    sign_in(owner)
    create(:log_entry, project:, occurred_at: 2.hours.ago)

    get member_monitoring_log_entries_path

    link = body.css("[data-test='bucket-link']").first
    expect(link).to be_present
    expect(link["href"]).to include("from=").and include("to=")
  end

  it "scelto un intervallo, l'elenco si restringe a quel momento" do
    sign_in(owner)
    dentro = create(:log_entry, project:, message: "Dentro la finestra", occurred_at: 2.hours.ago)
    fuori = create(:log_entry, project:, message: "Fuori dalla finestra", occurred_at: 20.hours.ago)

    get member_monitoring_log_entries_path(from: 3.hours.ago.iso8601, to: 1.hour.ago.iso8601)

    expect(response.body).to include(dentro.message)
    expect(response.body).not_to include(fuori.message)
  end

  it "con una finestra scelta si può tornare a tutto il periodo" do
    sign_in(owner)
    create(:log_entry, project:, occurred_at: 2.hours.ago)

    get member_monitoring_log_entries_path(from: 3.hours.ago.iso8601, to: 1.hour.ago.iso8601)

    expect(body.at_css("[data-test='logs-chart-reset']")).to be_present
  end

  # Il secondo guasto: i conteggi in cima non seguivano il filtro.
  it "i conteggi seguono la ricerca, col totale non filtrato accanto" do
    sign_in(owner)
    allow_n_plus_one do
      create(:log_entry, project:, message: "Resend fallito", level: :error)
      2.times { |i| create(:log_entry, project:, message: "Altro #{i}", level: :error) }
    end

    get member_monitoring_log_entries_path(q: "Resend")

    totale = body.at_css("[data-test='logs-stat-total']").text
    expect(totale).to include(I18n.t("member.monitoring.logs.count_of", filtered: 1, total: 3))
  end

  # La finestra del grafico segue la scelta: «solo oggi» parte da mezzanotte, un estremo solo si
  # completa da sé, e un intervallo rovesciato non manda in pezzi la pagina.
  # L'ora è fissata a mezzogiorno perché «un'ora fa» deve cadere nello stesso giorno del filtro:
  # eseguito fra mezzanotte e l'una, il log finiva nel giorno precedente, la finestra «da mezzanotte»
  # non lo comprendeva e il grafico spariva. Rosso una notte su ventiquattro, verde a riprovarlo la
  # mattina dopo — il modo peggiore di fallire.
  it "con «solo oggi» il grafico parte da mezzanotte" do
    travel_to(Time.current.change(hour: 12)) do
      sign_in(owner)
      create(:log_entry, project:, occurred_at: 1.hour.ago)

      get member_monitoring_log_entries_path(since: "today")

      expect(response).to have_http_status(:ok)
      expect(body.at_css("[data-test='logs-volume-chart']")).to be_present
    end
  end

  it "con la sola fine, l'inizio si completa da sé" do
    sign_in(owner)
    create(:log_entry, project:, occurred_at: 2.hours.ago)

    get member_monitoring_log_entries_path(to: 1.hour.ago.iso8601)

    expect(response).to have_http_status(:ok)
  end

  it "un intervallo rovesciato non manda in pezzi la pagina" do
    sign_in(owner)
    create(:log_entry, project:, occurred_at: 2.hours.ago)

    get member_monitoring_log_entries_path(from: 1.hour.ago.iso8601, to: 5.hours.ago.iso8601)

    expect(response).to have_http_status(:ok)
  end

  it "senza filtri il conteggio è un numero solo, non «3 di 3»" do
    sign_in(owner)
    create(:log_entry, project:)

    get member_monitoring_log_entries_path

    expect(body.at_css("[data-test='logs-stat-total']").text).not_to include(" di ")
  end
end
