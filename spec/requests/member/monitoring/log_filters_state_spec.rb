# frozen_string_literal: true

require "rails_helper"

# CYRA-579 — la barra dei log aveva cinque campi e nessun campo nascosto: ogni ricerca, ogni filtro
# applicato ripartiva da zero e cancellava tutto il resto. Quante righe per pagina, la finestra
# scelta sul grafico e — la peggiore — il filtro su UNA sola richiesta: chi arrivava dalla scheda di
# un errore per leggere i registri di quella richiesta e cercava una parola dentro si ritrovava,
# senza accorgersene, i risultati di tutta l'organizzazione. E niente in pagina diceva che quel
# filtro c'era.
RSpec.describe "Member — i log tengono i filtri quando si cerca", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  def campo(nome) = body.at_css("[data-test='logs-toolbar'] form input[name='#{nome}']")

  # Quello che il form della barra manderebbe DAVVERO al submit: è l'invio a essere lossy, quindi il
  # test guarda i campi che partono, non quelli che si vedono. I multi-valore (`release[]`) tornano
  # come array, così si possono rigirare tali e quali dentro una GET.
  def campi_del_form
    modulo = body.at_css("[data-test='logs-toolbar'] form")
    modulo.css("input[type='hidden'], input[type='datetime-local']").each_with_object({}) do |input, acc|
      next if input["value"].blank?

      nome = input["name"].to_s
      if nome.end_with?("[]")
        (acc[nome.delete_suffix("[]")] ||= []) << input["value"]
      else
        acc[nome] = input["value"]
      end
    end
  end

  describe "cercare dentro una sola richiesta" do
    let(:trace) { "e146fed6-1a2b-4c3d-8e4f-556677889900" }

    before do
      sign_in(owner)
      allow_n_plus_one do
        create(:log_entry, project:, trace_id: trace, message: "timeout dentro la richiesta")
        create(:log_entry, project:, trace_id: trace, message: "riga qualunque della richiesta")
        create(:log_entry, project:, trace_id: nil, message: "timeout fuori dalla richiesta")
      end
    end

    it "la ricerca resta dentro quella richiesta" do
      get member_monitoring_log_entries_path(trace_id: trace)
      get member_monitoring_log_entries_path(campi_del_form.merge(q: "timeout"))

      expect(response.body).to include("timeout dentro la richiesta")
      expect(response.body).not_to include("timeout fuori dalla richiesta")
    end

    it "la pagina dice che si sta guardando una sola richiesta" do
      get member_monitoring_log_entries_path(trace_id: trace)

      avviso = body.at_css("[data-test='logs-trace-filter']")
      expect(avviso).to be_present
      expect(avviso.text).to include(I18n.t("member.monitoring.logs.trace_filter"))
      expect(avviso.text).to include(trace)
    end

    it "il filtro sulla richiesta si toglie da dov'è, senza perdere la ricerca fatta" do
      get member_monitoring_log_entries_path(trace_id: trace, q: "timeout")

      href = body.at_css("[data-test='logs-trace-remove']")["href"]
      params = Rack::Utils.parse_nested_query(URI.parse(href).query)
      expect(params).not_to have_key("trace_id")
      expect(params["q"]).to eq("timeout")
    end

    it "senza quel filtro non compare nessun avviso" do
      get member_monitoring_log_entries_path

      expect(body.at_css("[data-test='logs-trace-filter']")).to be_nil
    end

    # Ci si arriva dalla scheda di un errore: se per quella richiesta non è arrivato niente, l'avviso
    # deve esserci lo stesso — è l'unica cosa che spiega perché l'elenco è vuoto.
    it "l'avviso c'è anche quando per quella richiesta non c'è nessun registro" do
      get member_monitoring_log_entries_path(trace_id: "richiesta-mai-vista")

      expect(body.at_css("[data-test='logs-no-match-trace']")).to be_present
      expect(body.at_css("[data-test='logs-trace-filter']")).to be_present
    end
  end

  describe "le altre scelte fatte prima" do
    before { sign_in(owner) }

    it "quante righe per pagina non torna a dieci quando si filtra" do
      allow_n_plus_one { 12.times { |i| create(:log_entry, project:, level: :error, message: "guasto numero #{i}") } }

      get member_monitoring_log_entries_path(per: 25)
      get member_monitoring_log_entries_path(campi_del_form.merge(level: [ "error" ]))

      expect(body.css("[data-test='log-entry-row']").size).to eq(12)
    end

    # La finestra viaggia negli estremi del periodo personalizzato, che sono campi veri della barra:
    # il test guarda che partano, non dove sono scritti.
    it "la finestra scelta sul grafico resta nel form" do
      create(:log_entry, project:, message: "riga nella finestra", occurred_at: Time.zone.parse("2026-07-09T14:05"))

      get member_monitoring_log_entries_path(from: "2026-07-09T14:00", to: "2026-07-09T14:10")

      expect(campi_del_form["from"]).to be_present
      expect(campi_del_form["to"]).to be_present
    end

    it "il filtro su un campo strutturato resta" do
      create(:log_entry, project:, message: "riga con campi", data: { "host" => "web-1" })

      get member_monitoring_log_entries_path(field: "host", value: "web-1")

      expect(campo("field")["value"]).to eq("host")
      expect(campo("value")["value"]).to eq("web-1")
    end

    it "le singole voci di un messaggio restano quelle" do
      riga = create(:log_entry, project:, level: :warning, message: "Coda piena",
                                fingerprint: Logs::Fingerprint.call(message: "Coda piena", level: :warning))

      get member_monitoring_log_entries_path(fingerprint: riga.fingerprint)

      expect(campo("fingerprint")["value"]).to eq(riga.fingerprint)
    end

    # `release` arriva dalle viste pronte come multi-valore: un solo campo col valore-array
    # manderebbe la stringa `["v1.2.3"]` e filtrerebbe su niente.
    it "la versione pubblicata scelta da una vista resta, anche se i valori sono più d'uno" do
      allow_n_plus_one do
        create(:log_entry, project:, release: "v1.2.3", message: "riga della versione nuova")
        create(:log_entry, project:, release: "v1.0.0", message: "riga della versione vecchia")
      end

      get member_monitoring_log_entries_path(release: [ "v1.2.3" ])
      get member_monitoring_log_entries_path(campi_del_form.merge(q: "riga"))

      expect(response.body).to include("riga della versione nuova")
      expect(response.body).not_to include("riga della versione vecchia")
    end

    it "il periodo scelto e il raggruppamento non si perdono" do
      create(:log_entry, project:, message: "riga qualunque")

      get member_monitoring_log_entries_path(range: "7d", grouped: "1")

      expect(campo("range")["value"]).to eq("7d")
      expect(campo("grouped")["value"]).to eq("1")
    end
  end
end
