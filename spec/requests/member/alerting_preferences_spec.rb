# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::AlertingPreferences", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  before { create(:membership, account: account, organization: organization, role: :member) }

  def sign_in(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  describe "GET show" do
    it "non autenticato → redirect login" do
      get member_notification_preferences_path
      expect(response).to redirect_to(login_path)
    end

    it "mostra le preferenze (default per chi non ne ha)" do
      sign_in(account)
      get member_notification_preferences_path
      expect(response).to have_http_status(:ok)
    end

    it "il testo delle ore silenziose elenca i guasti gravi che passano sempre — it/en (CYRA-479)" do
      {
        "it" => %w[sito server database cron],
        "en" => %w[site server database cron]
      }.each do |locale, terms|
        note = I18n.t("member.alerting.preferences.quiet_note", locale: locale)
        terms.each { |term| expect(note.downcase).to include(term), "#{locale}: manca '#{term}' in quiet_note" }
      end
    end

    it "il centro preferenze rende il testo aggiornato delle ore silenziose (CYRA-479)" do
      sign_in(account)
      get member_notification_preferences_path
      expect(response.body).to include(I18n.t("member.alerting.preferences.quiet_note"))
    end
  end

  # CYRA-443 — la pagina metteva 40+ avvisi × 3 colonne tutti aperti insieme, con una colonna che
  # ripeteva 40 volte un valore non modificabile. Qui si presidia la disposizione: colonna morta via,
  # gruppi che si aprono uno alla volta, ricerca, configurazioni pronte e Salva sempre raggiungibile.
  describe "GET show — la disposizione degli avvisi (CYRA-443)" do
    def doc_for(acc)
      sign_in(acc)
      get member_notification_preferences_path
      Nokogiri::HTML(response.body)
    end

    it "la colonna In-app sparisce dalla matrice: resta dichiarata una volta sola in cima" do
      doc = doc_for(account)
      # In cima: la riga dei canali dice che l'in-app arriva sempre e non si spegne.
      expect(doc.css("[data-test='pref-in-app-always']").size).to eq(1)
      expect(doc.text).to include(I18n.t("member.notifications.channels.in_app_hint"))
      # Nella matrice: due sole colonne per avviso, email e Telegram.
      riga = doc.at_css("[data-test='pref-row-ticket_assigned']")
      expect(riga.css("select").map { |s| s["data-test"] })
        .to eq(%w[pref-email-ticket_assigned pref-telegram-ticket_assigned])
      expect(riga.text).not_to include(I18n.t("member.notifications.channels.in_app"))
    end

    it "ogni gruppo di avvisi si apre e si chiude" do
      doc = doc_for(account)
      gruppi = doc.css("details[data-test^='pref-group-']")
      expect(gruppi.size).to eq(Notifications::Catalog.groups_for(account).size)
      expect(gruppi.css("summary").size).to eq(gruppi.size)
    end

    # CYRA-875 — CloseYourIt's own services are the gods' business.
    it "does not show the internal services group to a regular member" do
      expect(doc_for(account).at_css("[data-test='pref-group-services']")).to be_nil
    end

    it "chi non ha mai toccato nulla trova aperto solo il primo gruppo" do
      doc = doc_for(account)
      aperti = doc.css("details[data-test^='pref-group-'][open]").map { |g| g["data-test"] }
      expect(aperti).to eq([ "pref-group-tickets" ])
    end

    it "chi ha già scelto qualcosa trova aperto il gruppo che ha toccato, non il primo" do
      create(:alerting_preference, account: account, organization: organization,
                                   email_cadences: { "server_cpu" => "off" })
      doc = doc_for(account)
      aperti = doc.css("details[data-test^='pref-group-'][open]").map { |g| g["data-test"] }
      expect(aperti).to eq([ "pref-group-servers" ])
    end

    it "un campo cerca l'avviso per nome" do
      doc = doc_for(account)
      campo = doc.at_css("[data-test='pref-search']")
      expect(campo).to be_present
      expect(campo["placeholder"]).to eq(I18n.t("member.notifications.search.placeholder"))
    end

    it "tre configurazioni pronte scrivono la matrice in un gesto" do
      doc = doc_for(account)
      bottoni = doc.css("[data-test^='pref-preset-']")
      expect(bottoni.map { |b| b["value"] }).to eq(%w[essential everything urgent_only])
      expect(bottoni.map { |b| b["name"] }.uniq).to eq([ "preset" ])
    end

    it "il pulsante per salvare resta raggiungibile mentre si scorre" do
      doc = doc_for(account)
      barra = doc.at_css("[data-test='pref-save-bar']")
      expect(barra).to be_present
      expect(barra["class"]).to include("sticky")
      submit = barra.at_css("[data-test='pref-save-bar-submit']")
      expect(submit).to be_present
      expect(submit["type"]).to eq("submit")
    end
  end

  describe "PATCH update — configurazioni pronte (CYRA-443)" do
    it "«Solo urgenze» manda subito i guasti gravi e spegne il resto" do
      sign_in(account)
      patch member_notification_preferences_path, params: { preset: "urgent_only", quiet_hours_enabled: "0" }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.email_cadences["uptime_down"]).to eq("immediate")
      expect(pref.email_cadences["server_cpu"]).to eq("off")
      expect(pref.telegram_cadences["uptime_down"]).to eq("immediate")
      expect(response).to redirect_to(member_notification_preferences_path)
    end

    it "sostituisce le scelte fatte a mano: è quello che si chiede applicandone una" do
      create(:alerting_preference, account: account, organization: organization,
                                   email_cadences: { "server_cpu" => "immediate" })
      sign_in(account)
      patch member_notification_preferences_path, params: { preset: "urgent_only", quiet_hours_enabled: "0" }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.email_cadences["server_cpu"]).to eq("off")
    end

    it "una configurazione sconosciuta non scrive niente: vale quello che c'è nel form" do
      sign_in(account)
      patch member_notification_preferences_path, params: {
        preset: "bogus", quiet_hours_enabled: "0", email_cadences: { "ticket_assigned" => "weekly" }
      }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.email_cadences).to eq({ "ticket_assigned" => "weekly" })
    end

    it "non tocca i canali né le ore silenziose: quelle restano scelte a mano" do
      sign_in(account)
      patch member_notification_preferences_path, params: {
        preset: "everything", email_enabled: "0", telegram_enabled: "1",
        quiet_hours_enabled: "1", quiet_hours_start: "22", quiet_hours_end: "8"
      }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.email_enabled).to be(false)
      expect(pref.telegram_enabled).to be(true)
      expect(pref.quiet_hours_start).to eq(22)
      expect(pref.email_cadences["server_cpu"]).to eq("immediate")
    end
  end

  describe "PATCH update" do
    it "salva i toggle di canale email/telegram + min_level" do
      sign_in(account)
      patch member_notification_preferences_path, params: {
        email_enabled: "0", telegram_enabled: "1",
        min_level: ::Errors::Group.levels["warning"], quiet_hours_enabled: "0"
      }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref).to be_present
      expect(pref.email_enabled).to be(false)
      expect(pref.telegram_enabled).to be(true)
      expect(pref.min_level).to eq(::Errors::Group.levels["warning"])
      expect(response).to redirect_to(member_notification_preferences_path)
    end

    it "i select cadenza sono searchable (Ui::SelectComponent) con aria-label (a11y, no <label> visibile)" do
      sign_in(account)
      get member_notification_preferences_path
      doc = Nokogiri::HTML(response.body)
      select = doc.at_css("[data-test='pref-email-ticket_assigned']")
      expect(select.name).to eq("select") # resta un <select> nativo: submette senza JS
      expect(select["aria-label"]).to be_present
      expect(doc.at_css("div[data-controller='ui--select'] select[data-test='pref-email-ticket_assigned']")).to be_present
    end

    it "salva le cadenze per-notifica (email e telegram) nel jsonb" do
      sign_in(account)
      patch member_notification_preferences_path, params: {
        email_enabled: "1", quiet_hours_enabled: "0",
        email_cadences: { "ticket_assigned" => "weekly", "error_new" => "off" },
        telegram_cadences: { "ticket_assigned" => "daily" }
      }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.email_cadences["ticket_assigned"]).to eq("weekly")
      expect(pref.email_cadences["error_new"]).to eq("off")
      expect(pref.telegram_cadences["ticket_assigned"]).to eq("daily")
    end

    it "scarta event_type ignoti e cadenze non valide (allowlist)" do
      sign_in(account)
      patch member_notification_preferences_path, params: {
        email_enabled: "1", quiet_hours_enabled: "0",
        email_cadences: { "bogus_event" => "weekly", "ticket_assigned" => "not-a-cadence" }
      }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.email_cadences).to eq({})
    end

    it "quiet hours attive: salva la finestra" do
      sign_in(account)
      patch member_notification_preferences_path, params: {
        email_enabled: "1", quiet_hours_enabled: "1",
        quiet_hours_start: "22", quiet_hours_end: "8", quiet_hours_tz: "Europe/Rome"
      }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.quiet_hours_start).to eq(22)
      expect(pref.quiet_hours_end).to eq(8)
      expect(pref.quiet_hours_tz).to eq("Europe/Rome")
    end

    it "quiet hours disattivate: azzera la finestra" do
      sign_in(account)
      create(:alerting_preference, :quiet_nights, account: account, organization: organization)
      patch member_notification_preferences_path, params: { email_enabled: "1", quiet_hours_enabled: "0" }
      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.quiet_hours_start).to be_nil
      expect(pref.quiet_hours_end).to be_nil
    end

    it "salvataggio fallito → ri-renderizza show con 422" do
      sign_in(account)
      allow_any_instance_of(::Alerting::Preference).to receive(:update).and_return(false)
      patch member_notification_preferences_path, params: { email_enabled: "1", quiet_hours_enabled: "0" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET telegram_connection (tab Telegram)" do
    it "non autenticato → redirect login" do
      get member_telegram_connection_path
      expect(response).to redirect_to(login_path)
    end

    it "mostra la tab Telegram (scollegato)" do
      sign_in(account)
      get member_telegram_connection_path
      expect(response).to have_http_status(:ok)
    end

    it "mostra la tab Telegram (collegato)" do
      account.update!(telegram_chat_id: "123", telegram_username: "mario", telegram_linked_at: Time.current)
      sign_in(account)
      get member_telegram_connection_path
      expect(response).to have_http_status(:ok)
    end
  end

  # CYRA-444 — la pagina Telegram era il nome dell'account collegato e un pulsante per scollegarsi:
  # non diceva cosa arrivi su quel canale, non rimandava a dove si sceglie, e chi non era ancora
  # collegato non trovava la procedura col nome del bot. Telegram è uno dei tre canali di avviso:
  # la sua pagina deve insegnarlo da sola, perché fra le guide non c'è un ripiego.
  describe "GET telegram_connection — la pagina insegna il canale (CYRA-444)" do
    let(:bot) { "closeyourit_bot" }

    def stub_bot(username)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_USERNAME").and_return(username)
    end

    def doc_for(acc)
      sign_in(acc)
      get member_telegram_connection_path
      Nokogiri::HTML(response.body)
    end

    def connect_telegram!
      account.update!(telegram_chat_id: "123", telegram_username: "mario", telegram_linked_at: Time.current)
    end

    context "collegato" do
      before { connect_telegram! }

      it "spiega in due righe cosa arriva via Telegram" do
        stub_bot(bot)
        doc = doc_for(account)
        blocco = doc.at_css("[data-test='telegram-what']")
        expect(blocco).to be_present
        expect(blocco.text).to include(I18n.t("member.notifications.telegram.what_body_1"))
        expect(blocco.text).to include(I18n.t("member.notifications.telegram.what_body_2"))
      end

      it "rimanda alla pagina dove si scelgono gli avvisi, con la colonna Telegram evidenziata" do
        stub_bot(bot)
        doc = doc_for(account)
        link = doc.at_css("[data-test='telegram-choose-alerts']")
        expect(link).to be_present
        expect(link["href"]).to eq(member_notification_preferences_path(highlight: "telegram"))
        expect(link.text).to include(I18n.t("member.notifications.telegram.choose_alerts"))
      end

      it "dice anche cosa si può fare scrivendo al bot" do
        stub_bot(bot)
        doc = doc_for(account)
        comandi = doc.at_css("[data-test='telegram-commands']")
        expect(comandi).to be_present
        expect(comandi.text).to include("/nuovo-ticket").and include("/aiuto")
      end

      it "«Scollega» viene dopo il contenuto informativo, non prima" do
        stub_bot(bot)
        sign_in(account)
        get member_telegram_connection_path
        posizione = ->(test_id) { response.body.index(%(data-test="#{test_id}")) }
        expect(posizione.call("pref-telegram-disconnect")).to be_present
        expect(posizione.call("pref-telegram-disconnect")).to be > posizione.call("telegram-what")
        expect(posizione.call("pref-telegram-disconnect")).to be > posizione.call("telegram-choose-alerts")
      end
    end

    context "non collegato" do
      it "elenca i passi col nome esatto del bot" do
        stub_bot(bot)
        doc = doc_for(account)
        passi = doc.at_css("[data-test='telegram-connect-steps']")
        expect(passi).to be_present
        expect(passi.css("li").size).to be >= 3
        expect(doc.at_css("[data-test='telegram-bot-handle']").text).to include("@#{bot}")
        expect(doc.at_css("[data-test='pref-telegram-connect']")["href"]).to start_with("https://t.me/#{bot}?start=")
      end

      it "spiega comunque cosa arriva e dove si sceglie: serve a decidere se collegarsi" do
        stub_bot(bot)
        doc = doc_for(account)
        expect(doc.at_css("[data-test='telegram-what']")).to be_present
        expect(doc.at_css("[data-test='telegram-choose-alerts']")).to be_present
      end

      it "senza bot configurato non promette passi che non si possono fare" do
        stub_bot(nil)
        doc = doc_for(account)
        expect(response).to have_http_status(:ok)
        expect(doc.text).to include(I18n.t("member.notifications.telegram.not_configured"))
        expect(doc.at_css("[data-test='telegram-bot-handle']")).to be_nil
        expect(doc.at_css("[data-test='pref-telegram-connect']")).to be_nil
      end
    end
  end

  # CYRA-444 — chi arriva dalla pagina Telegram cerca UNA colonna fra due: gliela indichiamo invece
  # di lasciarlo contare le celle. Senza il parametro la pagina resta identica a prima.
  describe "GET show — colonna Telegram evidenziata (CYRA-444)" do
    it "col parametro highlight=telegram dice quale colonna guardare" do
      sign_in(account)
      get member_notification_preferences_path(highlight: "telegram")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='pref-highlight-telegram']")).to be_present
      expect(doc.at_css("[data-test='pref-cell-telegram-ticket_assigned']")["class"]).to include("ring-sky-300")
      # L'email resta com'era: si evidenzia una colonna, non si spegne l'altra.
      expect(doc.at_css("[data-test='pref-cell-email-ticket_assigned']")["class"]).not_to include("ring-sky-300")
    end

    it "senza parametro non evidenzia niente" do
      sign_in(account)
      get member_notification_preferences_path
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='pref-highlight-telegram']")).to be_nil
      expect(doc.at_css("[data-test='pref-cell-telegram-ticket_assigned']")["class"]).not_to include("ring-sky-300")
    end

    it "un valore inventato non evidenzia niente" do
      sign_in(account)
      get member_notification_preferences_path(highlight: "pippo")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='pref-highlight-telegram']")).to be_nil
    end
  end

  # CYRA-160 — il riepilogo periodico dei dati si accende da qui: è una preferenza personale di
  # consegna come le altre, e la pagina è quella dove si va a cercarla.
  describe "PATCH update — riepilogo periodico dei dati" do
    it "salva la frequenza scelta" do
      sign_in(account)
      patch member_notification_preferences_path, params: { report_cadence: "weekly", quiet_hours_enabled: "0" }

      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.report_cadence).to eq("weekly")
    end

    it "una frequenza inventata non entra nel salvataggio" do
      create(:alerting_preference, account: account, organization: organization, report_cadence: :weekly)
      sign_in(account)
      patch member_notification_preferences_path, params: { report_cadence: "ogni_tanto", quiet_hours_enabled: "0" }

      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.report_cadence).to eq("weekly")
    end

    it "si può spegnere" do
      create(:alerting_preference, account: account, organization: organization, report_cadence: :weekly)
      sign_in(account)
      patch member_notification_preferences_path, params: { report_cadence: "off", quiet_hours_enabled: "0" }

      pref = ::Alerting::Preference.find_by(account: account, organization: organization)
      expect(pref.report_cadence).to eq("off")
    end

    it "la pagina mostra il selettore della frequenza e la guida che lo spiega" do
      sign_in(account)
      get member_notification_preferences_path
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css("[data-test='pref-report-cadence']")).to be_present
      expect(doc.at_css("[data-test='pref-report-guide']")).to be_present
    end

    it "con le email spente lo dice, invece di lasciar credere che arriverà" do
      create(:alerting_preference, account: account, organization: organization,
                                   report_cadence: :weekly, email_enabled: false)
      sign_in(account)
      get member_notification_preferences_path

      expect(response.body).to include(I18n.t("member.notifications.report.email_off"))
    end
  end

  describe "DELETE telegram_connection" do
    it "scollega il Telegram dell'account" do
      account.update!(telegram_chat_id: "123", telegram_username: "mario", telegram_linked_at: Time.current)
      sign_in(account)
      delete member_telegram_connection_path
      expect(account.reload.telegram_chat_id).to be_nil
      expect(response).to redirect_to(member_telegram_connection_path)
    end
  end

  # CYRA-852 — il gruppo Telegram con argomenti è solo dell'owner.
  describe "gruppo Telegram con argomenti" do
    let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_USERNAME").and_return("closeyourit_bot")
    end

    it "l'owner vede la scheda col collegamento che fa scegliere il gruppo" do
      sign_in(owner)
      get member_telegram_connection_path

      link = Nokogiri::HTML(response.body).at_css("[data-test='telegram-group-connect']")
      expect(link["href"]).to match(%r{\Ahttps://t\.me/closeyourit_bot\?startgroup=[\w-]+&admin=manage_topics\z})
      code = link["href"][/startgroup=([\w-]+)/, 1]
      expect(Accounts::TelegramLinkCode.find_by(code: code).organization).to eq(organization)
    end

    it "chi non è owner non vede la scheda" do
      sign_in(account)
      get member_telegram_connection_path

      expect(response.body).not_to include("telegram-group")
    end

    it "l'owner scollega il gruppo" do
      Alerting::TelegramGroup.create!(organization: organization, account: owner, chat_id: "-100", title: "Avvisi")
      sign_in(owner)
      get member_telegram_connection_path
      expect(response.body).to include("telegram-group-connected")

      delete member_telegram_group_path

      expect(response).to redirect_to(member_telegram_connection_path)
      expect(Alerting::TelegramGroup.count).to eq(0)
    end

    it "chi non è owner non può scollegarlo" do
      Alerting::TelegramGroup.create!(organization: organization, account: owner, chat_id: "-100")
      sign_in(account)

      delete member_telegram_group_path

      expect(Alerting::TelegramGroup.count).to eq(1)
    end
  end
end
