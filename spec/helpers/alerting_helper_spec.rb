# frozen_string_literal: true

require "rails_helper"

RSpec.describe AlertingHelper, type: :helper do
  describe "#alerting_event_tone" do
    it "tipo noto → tono dedicato (icona + colori Tailwind)" do
      tone = helper.alerting_event_tone("error_new")
      expect(tone[:icon]).to eq("bug")
      expect(tone[:fg]).to eq("text-red-600 dark:text-red-400")
    end

    it "tipo sconosciuto → DEFAULT_TONE (campanella neutra)" do
      expect(helper.alerting_event_tone("boh")).to eq(AlertingHelper::DEFAULT_TONE)
    end
  end

  describe "#alerting_quiet_window (CYRA-479)" do
    it "finestra configurata → 'HH:MM–HH:MM'" do
      pref = build(:alerting_preference, quiet_hours_start: 22, quiet_hours_end: 7)
      expect(helper.alerting_quiet_window(pref)).to eq("22:00–07:00")
    end

    it "non configurata (estremi nil) → nil" do
      pref = build(:alerting_preference, quiet_hours_start: nil, quiet_hours_end: nil)
      expect(helper.alerting_quiet_window(pref)).to be_nil
    end

    it "finestra degenere (inizio uguale a fine) → nil, coerente con quiet_now? disattivata" do
      pref = build(:alerting_preference, quiet_hours_start: 22, quiet_hours_end: 22)
      expect(pref.quiet_now?(at: Time.utc(2026, 1, 1, 22, 0))).to be(false)
      expect(helper.alerting_quiet_window(pref)).to be_nil
    end

    it "preference nil → nil (guard)" do
      expect(helper.alerting_quiet_window(nil)).to be_nil
    end
  end

  # CYRA-323: ticket_*/chat_* sono conversazioni, distinguibili senza leggere il corpo.
  describe "#alerting_conversation?" do
    it "ticket_* e chat_* sono conversazioni" do
      expect(helper.alerting_conversation?("ticket_created")).to be(true)
      expect(helper.alerting_conversation?("ticket_commented")).to be(true)
      expect(helper.alerting_conversation?("chat_message")).to be(true)
      expect(helper.alerting_conversation?("chat_mentioned")).to be(true)
    end

    it "gli avvisi tecnici non sono conversazioni" do
      expect(helper.alerting_conversation?("server_container_down")).to be(false)
      expect(helper.alerting_conversation?("error_new")).to be(false)
    end
  end

  # CYRA-488: la gravità visiva riusa la criticità già definita nel catalogo (guasti gravi di
  # produzione), senza una terza tassonomia parallela.
  describe "#alerting_critical?" do
    it "i guasti gravi di produzione sono critici" do
      expect(helper.alerting_critical?("server_down")).to be(true)
      expect(helper.alerting_critical?("uptime_down")).to be(true)
      expect(helper.alerting_critical?(:cron_missed)).to be(true)
    end

    it "gli eventi di routine non sono critici" do
      expect(helper.alerting_critical?("uptime_up")).to be(false)
      expect(helper.alerting_critical?("ticket_created")).to be(false)
      expect(helper.alerting_critical?("bogus_event")).to be(false)
    end
  end
  describe "#unread_alerts_count" do
    it "senza account/organizzazione correnti → 0 (guard)" do
      expect(helper.unread_alerts_count).to eq(0)
    end

    it "conta solo le notifiche in-app NON lette dell'account nell'org corrente" do
      account = create(:account)
      organization = create(:organization)
      create(:membership, account: account, organization: organization)
      Current.account = account
      Current.organization = organization

      create(:alerting_notification, :unread, account: account, organization: organization, via: :in_app)
      create(:alerting_notification, :read,   account: account, organization: organization, via: :in_app)

      expect(helper.unread_alerts_count).to eq(1)
    end
  end
end
