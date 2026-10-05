# frozen_string_literal: true

require "rails_helper"

# CYRA-392 — l'interfaccia italiana mostrava stati, priorità e fasi in inglese, con durate come
# "10 days"/"about 3 hours". Qui si blinda che il lessico dei ticket sia scritto in italiano (e in
# inglese, per gli account in lingua inglese) e che le durate relative siano localizzate.
RSpec.describe "Lessico ticket in italiano (CYRA-392)", type: :model do
  include ActionView::Helpers::DateHelper

  STATUS_CODES = %w[open in_progress in_review resolved closed].freeze
  PRIORITY_CODES = %w[low medium high].freeze
  # CYRA-615 — l'elenco si LEGGE dal dominio invece di essere riscritto qui. Riscritto, un passaggio
  # nuovo poteva comparire in pagina senza il suo nome italiano: la copia in questo file restava
  # ferma, questa prova passava, e la parola inglese arrivava a chi guarda. Ora aggiungere una fase
  # senza la sua etichetta e la sua frase rende la suite rossa da sé.
  PHASE_KEYS = Agents::Workflows::PhaseResolver::PHASES
  # Valori di result["state"]/verdict del contratto agent-result mostrati come chip.
  STATE_KEYS = %w[
    workable needs_clarification waiting escalated submitted_for_approval delivered blocked
    already_delivered staging_released production_released approved changes_requested unavailable
  ].freeze
  # La striscia delle schede del ticket: unica sorgente dei nomi resi in pagina.
  STRISCIA = Rails.root.join("app/views/member/tickets/_ticket_tabs.html.erb")

  # Il sotto-albero effettivo, letto dal file YAML (nessun fallback silenzioso: la parità it/en la
  # garantisce il confronto diretto, non I18n.t che ricadrebbe su it per una chiave en mancante).
  def yaml_node(file, dotted)
    data = YAML.load_file(Rails.root.join(file))
    locale = data.keys.first
    dotted.split(".").reduce(data.fetch(locale)) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
  end

  def yaml_keys(file, dotted)
    node = yaml_node(file, dotted)
    node.is_a?(Hash) ? node.keys.map(&:to_s).sort : []
  end

  # CYRA-820 — l'elenco delle schede si LEGGE dalla striscia invece di essere ricopiato qui. Copiato,
  # una scheda nuova poteva comparire in pagina senza il suo nome: l'elenco in questo file restava
  # fermo e la prova passava lo stesso — è esattamente com'è arrivata «Questions» in produzione.
  def schede_della_striscia
    riga = File.readlines(STRISCIA).find { |r| r.include?("|name, icon|") }
    return [] if riga.nil?

    riga.scan(/\[\s*"([a-z_]+)"\s*,/).flatten
  end

  describe "status e priorità localizzati per code (senza toccare il code)" do
    it "espone tutti gli status di default in it e in en" do
      %w[it en].each do |locale|
        STATUS_CODES.each do |code|
          expect(I18n.t("ticketing.statuses.#{code}", locale: locale, raise: true)).to be_present
        end
      end
    end

    it "espone tutte le priorità di default in it e in en" do
      %w[it en].each do |locale|
        PRIORITY_CODES.each do |code|
          expect(I18n.t("ticketing.priorities.#{code}", locale: locale, raise: true)).to be_present
        end
      end
    end

    it "usa davvero l'italiano (non copie inglesi)" do
      expect(I18n.t("ticketing.statuses.in_review", locale: :it)).to eq("In revisione")
      expect(I18n.t("ticketing.statuses.resolved", locale: :it)).to eq("Risolto")
      expect(I18n.t("ticketing.priorities.high", locale: :it)).to eq("Alta")
    end

    it "tiene it ed en allineati sulle stesse chiavi" do
      %w[statuses priorities status_hints].each do |group|
        it_keys = yaml_keys("config/locales/ticketing/it.yml", "ticketing.#{group}")
        en_keys = yaml_keys("config/locales/ticketing/en.yml", "ticketing.#{group}")
        expect(it_keys).to eq(en_keys)
      end
    end
  end

  describe "una frase per stato: chi decide e il passo successivo" do
    it "ogni status di default ha la sua riga in it e in en" do
      %w[it en].each do |locale|
        STATUS_CODES.each do |code|
          expect(I18n.t("ticketing.status_hints.#{code}", locale: locale, raise: true)).to be_present
        end
      end
    end
  end

  describe "fasi dell'automazione (niente più 'Triage queued' in pagina italiana)" do
    it "ogni fase del workflow ha una label in it e in en" do
      %w[it en].each do |locale|
        PHASE_KEYS.each do |phase|
          expect(I18n.t("member.tickets.automation.phase.#{phase}", locale: locale, raise: true)).to be_present
        end
      end
    end

    it "traduce triage_queued in italiano" do
      expect(I18n.t("member.tickets.automation.phase.triage_queued", locale: :it)).to eq("In coda per la valutazione")
    end
  end

  describe "stati del payload agente localizzati (workable/blocked/…)" do
    it "ogni state del contratto ha una label in it e in en" do
      %w[it en].each do |locale|
        STATE_KEYS.each do |state|
          expect(I18n.t("member.tickets.automation.steps.state.#{state}", locale: locale, raise: true)).to be_present
        end
      end
    end

    # Il fallback [:it] maschererebbe una chiave en mancante ricadendo sull'italiano: la parità la
    # garantisce solo il confronto diretto dei file.
    it "tiene it ed en allineati su fasi e stati dell'automazione" do
      %w[member.tickets.automation.phase member.tickets.automation.steps.state].each do |group|
        it_keys = yaml_keys("config/locales/member/it.yml", group)
        en_keys = yaml_keys("config/locales/member/en.yml", group)
        expect(it_keys).to eq(en_keys)
      end
    end
  end

  # CYRA-384 — tradurre la sigla non bastava: «Lavorazione ferma» dice come si chiama lo stato, non
  # cosa comporta né chi si deve muovere. Ogni sigla porta la sua frase, e la frase c'è per TUTTE —
  # una spiegazione che compare a intermittenza è peggio di nessuna, perché fa sembrare speciali
  # proprio gli stati che l'hanno.
  describe "ogni sigla di stato ha la frase che la spiega" do
    it "ogni fase del workflow ha la sua frase in it e in en" do
      %w[it en].each do |locale|
        PHASE_KEYS.each do |phase|
          expect(I18n.t("member.tickets.automation.phase_hint.#{phase}", locale:, raise: true)).to be_present
        end
      end
    end

    it "ogni state del contratto ha la sua frase in it e in en" do
      %w[it en].each do |locale|
        STATE_KEYS.each do |state|
          expect(I18n.t("member.tickets.automation.steps.state_hint.#{state}", locale:, raise: true)).to be_present
        end
      end
    end

    it "ogni esito di un tentativo ha la sua frase, e una forma plurale per la riga che ne raccoglie tanti" do
      %w[it en].each do |locale|
        %w[approved rejected failed interrupted running awaiting_review].each do |outcome|
          expect(I18n.t("member.tickets.automation.steps.outcome_hint.#{outcome}", locale:, raise: true)).to be_present
          expect(I18n.t("member.tickets.automation.steps.outcome_plural.#{outcome}", locale:, raise: true)).to be_present
        end
      end
    end

    # Le fasi di ESECUZIONE hanno un vocabolario loro: tre nomi su cinque coincidono con una fase del
    # workflow che vuol dire un'altra cosa, e tenerli nello stesso albero li faceva scambiare.
    it "ogni fase di esecuzione ha il suo nome in it e in en" do
      %w[it en].each do |locale|
        %w[triage planner autopilot closer_staging closer_production].each do |phase|
          expect(I18n.t("member.tickets.automation.execution_phase.#{phase}", locale:, raise: true)).to be_present
        end
      end
    end

    it "tiene it ed en allineati su frasi, esiti e fasi di esecuzione" do
      %w[
        member.tickets.automation.phase_hint
        member.tickets.automation.execution_phase
        member.tickets.automation.steps.state_hint
        member.tickets.automation.steps.outcome_hint
        member.tickets.automation.steps.outcome_plural
        member.tickets.automation.summary.stopped
        member.tickets.automation.summary.needs
      ].each do |group|
        it_keys = yaml_keys("config/locales/member/it.yml", group)
        en_keys = yaml_keys("config/locales/member/en.yml", group)
        expect(it_keys).to eq(en_keys), group
      end
    end
  end

  # CYRA-820 — in mezzo a cinque nomi italiani la striscia diceva «Questions»: la voce non esisteva
  # in NESSUNA delle due lingue, quindi la parità restava verde (locale_parity_spec confronta it con
  # en) e i18n stampava a chi legge l'humanize della chiave. I nomi delle schede si compongono a
  # runtime (`t("member.tickets.tabs.#{name}")`), e raw_keys_on_screen_spec lascia fuori di proposito
  # le chiavi composte: la guardia è questa.
  describe "i nomi delle schede del ticket" do
    it "la striscia si lascia leggere: è da lì che arriva l'elenco, non da una copia scritta qui" do
      expect(schede_della_striscia).to include("detail", "questions", "discussion")
    end

    it "ogni scheda ha il suo nome scritto in it e in en" do
      %w[it en].each do |locale|
        nomi = yaml_node("config/locales/member/#{locale}.yml", "member.tickets.tabs") || {}
        mancanti = schede_della_striscia - nomi.keys.map(&:to_s)

        expect(mancanti).to be_empty, "schede senza nome in #{locale}: #{mancanti.join(', ')}"
      end
    end

    it "tiene it ed en allineate sulle stesse schede" do
      expect(yaml_keys("config/locales/member/it.yml", "member.tickets.tabs"))
        .to eq(yaml_keys("config/locales/member/en.yml", "member.tickets.tabs"))
    end

    # La scheda si chiama come la pagina che apre: due nomi per lo stesso posto sono due posti.
    it "chiama la scheda col nome del titolo che apre" do
      %w[it en].each do |locale|
        expect(I18n.t("member.tickets.tabs.questions", locale:, raise: true))
          .to eq(I18n.t("member.tickets.questions.title", locale:, raise: true))
      end

      expect(I18n.t("member.tickets.tabs.questions", locale: :it)).to eq("Domande")
      expect(I18n.t("member.tickets.tabs.questions", locale: :en)).to eq("Questions")
    end
  end

  describe "durate relative localizzate" do
    it "in italiano non escono in inglese" do
      freeze_time do
        I18n.with_locale(:it) do
          expect(time_ago_in_words(3.days.ago)).to eq("3 giorni")
          expect(time_ago_in_words(2.hours.ago)).to include("ore")
        end
      end
    end
  end
end
