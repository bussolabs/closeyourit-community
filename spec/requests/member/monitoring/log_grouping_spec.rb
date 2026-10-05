# frozen_string_literal: true

require "rails_helper"

# CYRA-348 — errori e prestazioni raggruppano le occorrenze uguali; i log no, e senza che fosse detto.
# Metà delle prime righe erano lo stesso messaggio ripetuto: su ventimila voci il volume smetteva di
# essere un'informazione.
RSpec.describe "Member — log raggruppati per messaggio", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def entry(message, occurred_at: Time.current, level: :warning)
    create(:log_entry, project:, level:, message:, occurred_at:,
                       fingerprint: Logs::Fingerprint.call(message:, level:))
  end

  def body = Nokogiri::HTML(response.body)

  it "di partenza la vista raggruppata è spenta: la lista è quella di sempre" do
    sign_in(owner)
    entry("Domain not verified")

    get member_monitoring_log_entries_path

    expect(body.at_css("[data-test='logs-groups']")).to be_nil
    expect(body.at_css("[data-test='log-entries-table']")).to be_present
  end

  it "acceso, un messaggio ripetuto è una riga sola col suo conteggio" do
    sign_in(owner)
    allow_n_plus_one do
      3.times { |i| entry("Domain not verified", occurred_at: i.hours.ago) }
      entry("Tutt'altro avviso")
    end

    get member_monitoring_log_entries_path(grouped: "1")

    gruppi = body.css("[data-test='logs-group']")
    expect(gruppi.size).to eq(2)
    expect(gruppi.first.at_css("[data-test='logs-group-count']").text.strip).to eq("3")
  end

  it "ogni gruppo dice la prima e l'ultima volta che è comparso" do
    sign_in(owner)
    allow_n_plus_one do
      entry("Ripetuto", occurred_at: 3.days.ago)
      entry("Ripetuto", occurred_at: 1.hour.ago)
    end

    get member_monitoring_log_entries_path(grouped: "1")

    expect(body.at_css("[data-test='logs-group-seen']")).to be_present
  end

  # Numeri, uuid e istanti cambiano a ogni occorrenza: se contassero, non si raggrupperebbe niente.
  it "due messaggi che differiscono solo per i numeri stanno insieme" do
    sign_in(owner)
    allow_n_plus_one do
      entry("Timeout dopo 1200ms sulla richiesta 42")
      entry("Timeout dopo 3400ms sulla richiesta 77")
    end

    get member_monitoring_log_entries_path(grouped: "1")

    expect(body.css("[data-test='logs-group']").size).to eq(1)
  end

  it "lo stesso testo a livelli diversi resta contato a parte" do
    sign_in(owner)
    allow_n_plus_one do
      entry("Coda piena", level: :warning)
      entry("Coda piena", level: :error)
    end

    get member_monitoring_log_entries_path(grouped: "1")

    expect(body.css("[data-test='logs-group']").size).to eq(2)
  end

  it "da un gruppo si arriva alle sue singole voci" do
    sign_in(owner)
    riga = entry("Domain not verified")
    entry("Tutt'altro")

    get member_monitoring_log_entries_path(grouped: "1", fingerprint: riga.fingerprint)

    expect(response.body).to include('data-test="logs-fingerprint-filter"')
  end

  it "la scelta resta nell'indirizzo, quindi si condivide e si torna indietro" do
    sign_in(owner)
    entry("Domain not verified")

    get member_monitoring_log_entries_path(grouped: "1")

    expect(body.at_css("[data-test='logs-group-by-none']")["href"]).not_to include("grouped=1")
  end

  # Le righe entrate prima dell'impronta non sono raggruppabili: dirlo è meglio che farle sparire.
  it "dichiara quante voci restano fuori perché non hanno un raggruppamento" do
    sign_in(owner)
    create(:log_entry, project:, message: "Vecchia", fingerprint: nil)

    get member_monitoring_log_entries_path(grouped: "1")

    expect(response.body).to include('data-test="logs-ungrouped"')
  end

  # CYRA-578 — la vista si fermava ai primi cinquanta gruppi e taceva sul resto: le occorrenze fuori
  # erano l'otto per cento del totale, e i gruppi più piccoli — quelli comparsi oggi per la prima
  # volta — erano proprio quelli che restavano fuori. Cioè la funzione nascondeva i messaggi nuovi.
  describe "i gruppi oltre il fondo della pagina" do
    let(:nomi) { %w[alfa bravo charlie delta echo foxtrot golf hotel india juliett kilo lima mike] }

    # Tredici messaggi diversi, il primo con due occorrenze: più di quanti ne stia in una pagina.
    def tredici_messaggi_diversi
      allow_n_plus_one do
        entry("Guasto alfa sul canale")
        nomi.each { |nome| entry("Guasto #{nome} sul canale") }
      end
    end

    def messaggi_mostrati = body.css("[data-test='logs-group-link']").map { |a| a.text.strip }

    it "si sfoglia invece di fermarsi, e dice quanti messaggi diversi ci sono" do
      sign_in(owner)
      tredici_messaggi_diversi

      get member_monitoring_log_entries_path(grouped: "1")

      piede = body.at_css("[data-test='logs-groups-pagination']")
      expect(piede).to be_present
      expect(piede.text).to include("13")
      expect(messaggi_mostrati.size).to eq(Pagination::DEFAULT_PER)
      expect(piede.at_css("[data-test='pagination-next']")).to be_present
    end

    it "la pagina successiva mostra i messaggi rimasti: nessuno perso, nessuno doppio" do
      sign_in(owner)
      tredici_messaggi_diversi

      get member_monitoring_log_entries_path(grouped: "1")
      prima = messaggi_mostrati
      get member_monitoring_log_entries_path(grouped: "1", page: 2)
      seconda = messaggi_mostrati

      expect(seconda.size).to eq(13 - Pagination::DEFAULT_PER)
      expect(prima & seconda).to be_empty
      expect((prima + seconda).uniq.size).to eq(13)
    end

    it "quante righe per pagina si sceglie, come nella lista" do
      sign_in(owner)
      tredici_messaggi_diversi

      get member_monitoring_log_entries_path(grouped: "1", per: 25)

      expect(messaggi_mostrati.size).to eq(13)
    end

    # Un numero di pagina oltre l'ultima non deve svuotare la vista senza spiegazioni.
    it "una pagina che non esiste riporta all'ultima" do
      sign_in(owner)
      tredici_messaggi_diversi

      get member_monitoring_log_entries_path(grouped: "1", page: 99)

      expect(messaggi_mostrati).not_to be_empty
    end
  end

  # CYRA-578 — nella vista raggruppata sparivano ricerca, filtri, periodo e pagine: per restringere a
  # un progetto bisognava spegnere il raggruppamento, e si perdeva il punto in cui si era.
  describe "filtrare mentre si raggruppa" do
    it "ricerca, filtri e periodo restano al loro posto" do
      sign_in(owner)
      entry("Domain not verified")

      get member_monitoring_log_entries_path(grouped: "1")

      expect(body.at_css("[data-test='logs-toolbar']")).to be_present
      expect(body.at_css("[data-test='logs-search']")).to be_present
      expect(body.at_css("[data-test='filter-project']")).to be_present
      expect(body.at_css("[data-test='filter-level']")).to be_present
      expect(body.at_css("[data-test='filter-range']")).to be_present
    end

    it "applicare un filtro non spegne il raggruppamento" do
      sign_in(owner)
      entry("Domain not verified")

      get member_monitoring_log_entries_path(grouped: "1")

      hidden = body.at_css("[data-test='logs-toolbar'] input[name='grouped']")
      expect(hidden).to be_present
      expect(hidden["value"]).to eq("1")
    end

    it "restringere a un progetto lascia solo i suoi messaggi" do
      sign_in(owner)
      altro = create(:project, organization:)
      allow_n_plus_one do
        entry("Domain not verified")
        create(:log_entry, project: altro, level: :warning, message: "Coda piena",
                           fingerprint: Logs::Fingerprint.call(message: "Coda piena", level: :warning))
      end

      get member_monitoring_log_entries_path(grouped: "1", project_id: [ altro.id ])

      gruppi = body.css("[data-test='logs-group']")
      expect(gruppi.size).to eq(1)
      expect(gruppi.first.text).to include("Coda piena")
    end

    # CYRA-924 — no count in the bar: the counts line above the panel says it.
    it "the bar carries no count" do
      sign_in(owner)
      allow_n_plus_one { 3.times { |i| entry("Domain not verified", occurred_at: i.hours.ago) } }

      get member_monitoring_log_entries_path(grouped: "1")

      expect(body.at_css("[data-test='logs-toolbar']").text).not_to match(/\d+ (distinct messages|messaggi? divers[oi]|logs?)\b/)
    end
  end
end
