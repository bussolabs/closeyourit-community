# frozen_string_literal: true

require "rails_helper"

# CYRA-478 — in ventiquattro ore erano scattati quasi duemila avvisi, con centinaia di notifiche non
# lette su oltre cento pagine senza filtri: non c'era modo di sapere quale regola producesse il
# rumore, né di zittirla per qualche ora senza spegnerla. Così un guasto vero restava sepolto.
RSpec.describe "Member::Alerting — rumore e silenzio (CYRA-478)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def rule(name:, **attrs) = create(:alerting_rule, organization: org, name: name, **attrs)

  def fired(rule_record, times:, at: 2.hours.ago)
    allow_n_plus_one do
      times.times { create(:alerting_notification, organization: org, rule: rule_record, account: owner, project: project, created_at: at) }
    end
  end

  describe "trovare la regola più rumorosa" do
    it "l'elenco mostra quante volte ciascuna è scattata nell'ultimo giorno e nell'ultima settimana" do
      rumorosa = rule(name: "Rumorosa")
      quieta = rule(name: "Quieta")
      fired(rumorosa, times: 4)
      fired(quieta, times: 1, at: 3.days.ago)

      get member_alerting_rules_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='alerting-rule-fired-24h-#{rumorosa.id}']").text).to include("4")
      expect(doc.at_css("[data-test='alerting-rule-fired-7d-#{quieta.id}']").text).to include("1")
      expect(doc.at_css("[data-test='alerting-rule-fired-24h-#{quieta.id}']").text).to include("—")
    end

    it "le più rumorose sono messe in evidenza" do
      rumorosa = rule(name: "Rumorosa")
      quieta = rule(name: "Quieta")
      fired(rumorosa, times: 9)
      fired(quieta, times: 1)

      get member_alerting_rules_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='alerting-rule-noisy-#{rumorosa.id}']")).to be_present
      expect(doc.at_css("[data-test='alerting-rule-noisy-#{quieta.id}']")).to be_nil
    end

    it "si può ordinare dalla più rumorosa" do
      get member_alerting_rules_path(sort: "-fired_24h")

      expect(response).to have_http_status(:ok)
    end
  end

  describe "silenziare senza spegnere" do
    it "silenzia per un'ora: la regola resta attiva ma non notifica" do
      target = rule(name: "Da zittire")

      put member_alerting_rule_mute_path(target, hours: "1")

      expect(target.reload.muted_until).to be_within(1.minute).of(1.hour.from_now)
      expect(target).to be_enabled
      expect(target).to be_muted
      expect(Alerting::Rule.notifying).not_to include(target)
      expect(Alerting::Rule.enabled).to include(target)
    end

    it "il silenzio si toglie prima della scadenza" do
      target = rule(name: "Zittita", muted_until: 1.day.from_now)

      delete member_alerting_rule_mute_path(target)

      expect(target.reload.muted_until).to be_nil
      expect(Alerting::Rule.notifying).to include(target)
    end

    it "una durata inventata non silenzia niente" do
      target = rule(name: "Intatta")

      put member_alerting_rule_mute_path(target, hours: "999")

      expect(target.reload.muted_until).to be_nil
    end

    it "lo stato silenziato si vede nell'elenco, distinto da spenta" do
      zittita = rule(name: "Zittita", muted_until: 2.hours.from_now)

      get member_alerting_rules_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='alerting-rule-muted-#{zittita.id}']")).to be_present
      expect(doc.at_css("[data-test='alerting-rule-muted-#{zittita.id}']").text.strip)
        .to eq(I18n.t("member.alerting.rules.status_muted"))
    end
  end

  describe "filtrare le notifiche" do
    it "per stato di lettura" do
      # I titoli sono uguali per costruzione: si contano le righe, non le stringhe.
      allow_n_plus_one do
        create(:alerting_notification, organization: org, account: owner, project: project, read_at: 1.hour.ago)
        create(:alerting_notification, organization: org, account: owner, project: project)
      end

      get member_alerting_notifications_path(read: "unread")
      unread_rows = Nokogiri::HTML(response.body).css("[data-test^='notification-']").size

      get member_alerting_notifications_path
      all_rows = Nokogiri::HTML(response.body).css("[data-test^='notification-']").size

      expect(unread_rows).to be < all_rows
    end

    it "il pannello dei filtri è in pagina" do
      create(:alerting_notification, organization: org, account: owner, project: project)

      get member_alerting_notifications_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='notifications-filters']")).to be_present
      expect(doc.at_css("[data-test='notifications-filter-event']")).to be_present
      expect(doc.at_css("[data-test='notifications-filter-project']")).to be_present
      expect(doc.at_css("[data-test='notifications-filter-read']")).to be_present
    end
  end
end
