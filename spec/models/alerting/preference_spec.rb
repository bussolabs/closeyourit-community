# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Preference, type: :model do
  describe "factory" do
    it "produce un record valido" do
      expect(build(:alerting_preference)).to be_valid
    end
  end

  # CYRA-236: anche le preferenze personali accettano min_level via CLI/SDK, dove arriva come NOME del
  # livello. La coercizione nome→intero è condivisa con Alerting::Rule.
  describe "min_level" do
    it "accetta nil" do
      expect(build(:alerting_preference, min_level: nil)).to be_valid
    end

    it "accetta il nome del livello e lo converte nell'intero corrispondente" do
      pref = build(:alerting_preference, min_level: "error")
      expect(pref).to be_valid
      expect(pref.min_level).to eq(Errors::Group.levels["error"])
    end

    it "rifiuta un nome di livello inesistente invece di salvarne uno qualsiasi" do
      pref = build(:alerting_preference, min_level: "bogus")
      expect(pref).not_to be_valid
      expect(pref.errors[:min_level]).to be_present
    end
  end

  describe "unicità [organization, account]" do
    it "rifiuta una seconda preferenza per la stessa coppia" do
      account = create(:account)
      organization = create(:organization)
      create(:alerting_preference, account: account, organization: organization)
      dup = build(:alerting_preference, account: account, organization: organization)
      expect(dup).not_to be_valid
    end
  end

  describe "#source_enabled?" do
    it "riflette errors_enabled" do
      expect(build(:alerting_preference, errors_enabled: false).source_enabled?("error_new")).to be(false)
      expect(build(:alerting_preference, errors_enabled: true).source_enabled?("error_regression")).to be(true)
    end

    it "riflette uptime_enabled" do
      expect(build(:alerting_preference, uptime_enabled: false).source_enabled?("uptime_down")).to be(false)
      expect(build(:alerting_preference, uptime_enabled: true).source_enabled?("uptime_up")).to be(true)
    end

    it "l'avviso di lentezza (uptime_slow) segue la sorgente uptime" do
      expect(build(:alerting_preference, uptime_enabled: false).source_enabled?("uptime_slow")).to be(false)
      expect(build(:alerting_preference, uptime_enabled: true).source_enabled?("uptime_slow")).to be(true)
    end
  end

  describe "#quiet_now? (range notturno 22→8 Europe/Rome)" do
    let(:pref) { build(:alerting_preference, :quiet_nights) }

    it "è quiet a Rome 23:00" do
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 15, 22, 0))).to be(true)
    end

    it "non è quiet a Rome 12:00" do
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 15, 11, 0))).to be(false)
    end

    it "confine: a Rome 07:59 è ancora quiet, a Rome 08:00 non più" do
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 15, 6, 59))).to be(true)
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 15, 7, 0))).to be(false)
    end

    it "senza quiet hours configurate è sempre false" do
      expect(build(:alerting_preference).quiet_now?(at: Time.utc(2026, 1, 15, 3, 0))).to be(false)
    end
  end

  describe ".for" do
    let(:account) { create(:account) }
    let(:organization) { create(:organization) }

    it "ritorna un default non persistito (tutto abilitato) quando non esiste" do
      pref = described_class.for(account: account, organization: organization)
      expect(pref).not_to be_persisted
      expect(pref.in_app_enabled).to be(true)
      expect(pref.email_enabled).to be(true)
    end

    it "ritorna la preferenza persistita quando esiste" do
      existing = create(:alerting_preference, account: account, organization: organization, email_enabled: false)
      expect(described_class.for(account: account, organization: organization)).to eq(existing)
    end
  end

  describe "#source_enabled? — performance + tipi non gestiti" do
    it "riflette performance_enabled per metric_threshold" do
      expect(build(:alerting_preference, performance_enabled: false).source_enabled?("metric_threshold")).to be(false)
      expect(build(:alerting_preference, performance_enabled: true).source_enabled?("metric_threshold")).to be(true)
    end

    it "tipo ignoto → false" do
      expect(build(:alerting_preference).source_enabled?("bogus_event")).to be(false)
    end
  end

  describe "#source_enabled? — chat" do
    it "riflette chat_enabled per chat_message e chat_mentioned" do
      expect(build(:alerting_preference, chat_enabled: false).source_enabled?("chat_message")).to be(false)
      expect(build(:alerting_preference, chat_enabled: false).source_enabled?("chat_mentioned")).to be(false)
      expect(build(:alerting_preference, chat_enabled: true).source_enabled?("chat_message")).to be(true)
      expect(build(:alerting_preference, chat_enabled: true).source_enabled?("chat_mentioned")).to be(true)
    end
  end

  describe "#source_enabled? — server (inclusi eventi database)" do
    it "riflette servers_enabled per tutti gli eventi server_*, database compresi" do
      %w[server_down server_cpu server_smart_failing
         server_db_down server_db_connections server_db_connection_usage server_replication_lag
         server_replication_down server_replication_up server_data_volume_disk server_inode
         server_container_restart_loop server_container_stable].each do |event|
        expect(build(:alerting_preference, servers_enabled: false).source_enabled?(event)).to be(false)
        expect(build(:alerting_preference, servers_enabled: true).source_enabled?(event)).to be(true)
      end
    end
  end

  describe "#quiet_now? — range diurno e degenere" do
    it "range diurno 9→17: quiet a Rome 12:00, non quiet a Rome 08:00" do
      pref = build(:alerting_preference, quiet_hours_start: 9, quiet_hours_end: 17, quiet_hours_tz: "Europe/Rome")
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 15, 11, 0))).to be(true)
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 15, 7, 0))).to be(false)
    end

    it "start uguale a end → mai quiet" do
      pref = build(:alerting_preference, quiet_hours_start: 9, quiet_hours_end: 9, quiet_hours_tz: "Europe/Rome")
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 15, 8, 0))).to be(false)
    end
  end

  describe "#email_cadence_for" do
    it "default immediata quando l'evento non è nella mappa" do
      expect(build(:alerting_preference, email_cadences: {}).email_cadence_for("ticket_assigned"))
        .to eq(Notifications::Cadence::IMMEDIATE)
    end

    it "restituisce il valore salvato nella mappa" do
      pref = build(:alerting_preference, email_cadences: { "ticket_assigned" => "weekly" })
      expect(pref.email_cadence_for("ticket_assigned")).to eq("weekly")
    end

    it "ricade sul default se il valore salvato è ignoto" do
      pref = build(:alerting_preference, email_cadences: { "ticket_assigned" => "bogus" })
      expect(pref.email_cadence_for("ticket_assigned")).to eq(Notifications::Cadence::IMMEDIATE)
    end

    it "off quando il canale email è spento (a prescindere dalla mappa)" do
      pref = build(:alerting_preference, email_enabled: false,
                                         email_cadences: { "ticket_assigned" => "immediate" })
      expect(pref.email_cadence_for("ticket_assigned")).to eq(Notifications::Cadence::OFF)
    end
  end

  describe "#telegram_cadence_for" do
    it "off quando il canale Telegram è spento (a prescindere dalla mappa)" do
      pref = build(:alerting_preference, telegram_enabled: false,
                                         telegram_cadences: { "ticket_assigned" => "daily" })
      expect(pref.telegram_cadence_for("ticket_assigned")).to eq(Notifications::Cadence::OFF)
    end

    it "default immediate quando il canale è acceso ma l'evento non è impostato" do
      pref = build(:alerting_preference, telegram_enabled: true, telegram_cadences: {})
      expect(pref.telegram_cadence_for("ticket_assigned")).to eq(Notifications::Cadence::IMMEDIATE)
    end

    it "restituisce il valore salvato quando il canale è acceso" do
      pref = build(:alerting_preference, telegram_enabled: true,
                                         telegram_cadences: { "ticket_assigned" => "immediate" })
      expect(pref.telegram_cadence_for("ticket_assigned")).to eq(Notifications::Cadence::IMMEDIATE)
    end
  end

  describe "#channels_for" do
    it "email immediata → consegna senza bucket" do
      pref = build(:alerting_preference, email_cadences: { "ticket_assigned" => "immediate" })
      expect(pref.channels_for("ticket_assigned")[:email]).to eq(deliver: true, bucket: nil)
    end

    it "email settimanale → consegna con bucket :weekly (trattenuta per il digest)" do
      pref = build(:alerting_preference, email_cadences: { "ticket_assigned" => "weekly" })
      expect(pref.channels_for("ticket_assigned")[:email]).to eq(deliver: true, bucket: :weekly)
    end

    it "email off → nessuna consegna" do
      pref = build(:alerting_preference, email_cadences: { "ticket_assigned" => "off" })
      expect(pref.channels_for("ticket_assigned")[:email]).to eq(deliver: false, bucket: nil)
    end

    it "telegram: off se il canale è spento" do
      pref = build(:alerting_preference, telegram_enabled: false,
                                         telegram_cadences: { "ticket_assigned" => "immediate" })
      expect(pref.channels_for("ticket_assigned", connected_telegram: true)[:telegram])
        .to eq(deliver: false, bucket: nil)
    end

    it "telegram: off se l'account non è collegato, anche a canale acceso" do
      pref = build(:alerting_preference, telegram_enabled: true,
                                         telegram_cadences: { "ticket_assigned" => "immediate" })
      expect(pref.channels_for("ticket_assigned", connected_telegram: false)[:telegram])
        .to eq(deliver: false, bucket: nil)
    end

    it "telegram: consegna quando canale acceso + account collegato" do
      pref = build(:alerting_preference, telegram_enabled: true,
                                         telegram_cadences: { "ticket_assigned" => "daily" })
      expect(pref.channels_for("ticket_assigned", connected_telegram: true)[:telegram])
        .to eq(deliver: true, bucket: :daily)
    end
  end

  # `source_enabled?` decide se un avviso parte o resta fermo: i rami senza test erano proprio quelli
  # senza interruttore dedicato (automazione, sicurezza, SEO, embedding), dove un `false` di troppo
  # spegnerebbe in silenzio avvisi che devono sempre partire.
  describe "#source_enabled?" do
    let(:pref) { build(:alerting_preference, tickets_enabled: false, chat_enabled: false) }

    it "i ticket seguono l'interruttore dei ticket" do
      expect(pref.source_enabled?("ticket_assigned")).to be(false)
      expect(build(:alerting_preference, tickets_enabled: true).source_enabled?("ticket_mentioned")).to be(true)
    end

    it "la chat segue l'interruttore della chat" do
      expect(pref.source_enabled?("chat_mentioned")).to be(false)
      expect(build(:alerting_preference, chat_enabled: true).source_enabled?("chat_message")).to be(true)
    end

    it "gli allarmi sull'automazione partono sempre: non hanno un interruttore da spegnere" do
      expect(pref.source_enabled?("agents_stalled")).to be(true)
      expect(pref.source_enabled?("agents_host_failing")).to be(true)
      expect(pref.source_enabled?("agents_host_stale")).to be(true)
    end

    it "sicurezza delle dipendenze e runtime fuori supporto partono sempre" do
      expect(pref.source_enabled?("vulnerability_new")).to be(true)
      expect(pref.source_enabled?("runtime_eol")).to be(true)
    end

    it "i rilievi SEO e il servizio di embedding partono sempre" do
      expect(pref.source_enabled?("seo_issue_new")).to be(true)
      expect(pref.source_enabled?("embedding_down")).to be(true)
    end

    it "un tipo sconosciuto non parte: meglio muto che un avviso che nessuno sa leggere" do
      expect(pref.source_enabled?("qualcosa_che_non_esiste")).to be(false)
    end
  end

  # CYRA-160 — il riepilogo periodico dei DATI (traffico, errori, disponibilità). Non è un avviso:
  # non nasce da un evento, parte a calendario. Qui si presidia quando è dovuto.
  describe "#report_due?" do
    let(:lunedi) { Time.zone.local(2026, 8, 10, 8, 0) }

    it "spento → non è mai dovuto" do
      pref = build(:alerting_preference, report_cadence: :off)
      expect(pref.report_due?(lunedi)).to be(false)
    end

    it "ogni giorno, mai inviato → è dovuto" do
      pref = build(:alerting_preference, report_cadence: :daily, report_last_sent_at: nil)
      expect(pref.report_due?(lunedi)).to be(true)
    end

    it "ogni giorno, già inviato stamattina → non è più dovuto oggi" do
      pref = build(:alerting_preference, report_cadence: :daily, report_last_sent_at: lunedi - 1.hour)
      expect(pref.report_due?(lunedi)).to be(false)
    end

    it "ogni giorno, inviato ieri → torna dovuto" do
      pref = build(:alerting_preference, report_cadence: :daily, report_last_sent_at: lunedi - 1.day)
      expect(pref.report_due?(lunedi)).to be(true)
    end

    it "ogni settimana, inviato la settimana scorsa e oggi è lunedì → è dovuto" do
      pref = build(:alerting_preference, report_cadence: :weekly, report_last_sent_at: lunedi - 7.days)
      expect(pref.report_due?(lunedi)).to be(true)
    end

    it "ogni settimana, inviato lunedì → mercoledì non è dovuto" do
      pref = build(:alerting_preference, report_cadence: :weekly, report_last_sent_at: lunedi)
      expect(pref.report_due?(lunedi + 2.days)).to be(false)
    end

    it "ogni mese, inviato il mese scorso e oggi è il primo → è dovuto" do
      primo = Time.zone.local(2026, 9, 1, 8, 0)
      pref = build(:alerting_preference, report_cadence: :monthly, report_last_sent_at: primo - 20.days)
      expect(pref.report_due?(primo)).to be(true)
    end

    it "ogni mese, già inviato questo mese → non è dovuto" do
      pref = build(:alerting_preference, report_cadence: :monthly,
                                         report_last_sent_at: Time.zone.local(2026, 8, 1, 8, 0))
      expect(pref.report_due?(Time.zone.local(2026, 8, 20, 8, 0))).to be(false)
    end

    # Il report è un'email: chi ha spento le email ha spento anche questa. Altrimenti il canale
    # spento resterebbe aperto proprio dove nessuno lo cerca.
    it "email spente → non parte, anche con la frequenza impostata" do
      pref = build(:alerting_preference, report_cadence: :weekly, email_enabled: false)
      expect(pref.report_due?(lunedi)).to be(false)
    end
  end

  describe "#report_range" do
    it "traduce la frequenza nella finestra di dati da riassumere" do
      expect(build(:alerting_preference, report_cadence: :daily).report_range).to eq("24h")
      expect(build(:alerting_preference, report_cadence: :weekly).report_range).to eq("7d")
      expect(build(:alerting_preference, report_cadence: :monthly).report_range).to eq("30d")
    end

    it "spento → nessuna finestra" do
      expect(build(:alerting_preference, report_cadence: :off).report_range).to be_nil
    end
  end
end
