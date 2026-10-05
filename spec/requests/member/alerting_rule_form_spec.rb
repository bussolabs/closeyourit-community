# frozen_string_literal: true

require "rails_helper"

# CYRA-481 — il form mostrava tutti i campi per tutti gli eventi e si scusava nelle note, esponendo
# identificatori del codice («Solo regole metric_threshold», «server_cpu/mem/disk/temp») in
# un'interfaccia italiana; l'elenco degli eventi era una lista piatta di ventitré voci.
RSpec.describe "Member::AlertingRules — il form (CYRA-481)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def field(body, test_id) = Nokogiri::HTML(body).at_css("[data-test='#{test_id}']")

  describe "solo i campi che servono" do
    it "su una regola di errore restano livello e «solo non gestiti», non le soglie" do
      rule = create(:alerting_rule, organization: org, event_type: :error_new)

      get edit_member_alerting_rule_path(rule)

      expect(field(response.body, "alerting-rule-level")).not_to be_nil
      expect(field(response.body, "alerting-rule-level")["hidden"]).to be_nil
      expect(field(response.body, "alerting-rule-server-threshold")["hidden"]).not_to be_nil
      expect(field(response.body, "alerting-rule-threshold")["hidden"]).not_to be_nil
    end

    it "su una regola di server resta la soglia, non il livello né i progetti" do
      rule = create(:alerting_rule, organization: org, event_type: :server_cpu, threshold: 90)

      get edit_member_alerting_rule_path(rule)

      expect(field(response.body, "alerting-rule-server-threshold")["hidden"]).to be_nil
      expect(field(response.body, "alerting-rule-level")["hidden"]).not_to be_nil
      expect(field(response.body, "alerting-rule-projects")["hidden"]).not_to be_nil
    end

    it "i campi nascosti restano nel DOM: modificare la regola non azzera ciò che non si vede" do
      rule = create(:alerting_rule, organization: org, event_type: :server_cpu, threshold: 90, throttle_seconds: 600)

      get edit_member_alerting_rule_path(rule)
      nascosto = field(response.body, "alerting-rule-level")
      expect(nascosto).to be_present

      patch member_alerting_rule_path(rule), params: { name: rule.name, event_type: "server_cpu",
                                                       threshold: 95, throttle_minutes: 10 }

      expect(rule.reload.threshold.to_i).to eq(95)
    end
  end

  describe "gli eventi raggruppati" do
    it "la tendina ha le famiglie, non ventitré voci in fila" do
      get new_member_alerting_rule_path

      doc = Nokogiri::HTML(response.body)
      groups = doc.css("[data-test='alerting-rule-event-select'] optgroup")
      expect(groups.size).to be >= 5
      expect(groups.map { |g| g["label"] }).to include(I18n.t("member.notifications.groups.errors"))
    end

    it "sotto la tendina c'è la riga che dice quando succede l'evento" do
      rule = create(:alerting_rule, organization: org, event_type: :cron_missed)

      get edit_member_alerting_rule_path(rule)

      hint = field(response.body, "alerting-rule-event-hint")
      expect(hint.text).to eq(Notifications::Catalog.entry("cron_missed").description)
    end
  end

  # CYRA-465 — l'evento «temperatura del server oltre soglia» è proponibile solo se una macchina della
  # flotta la riporta: su una VM i sensori non esistono e sarebbe una regola che non può scattare. In
  # modifica di una regola già impostata su di esso resta comunque, per non alterarla senza volerlo.
  describe "l'evento temperatura del server (CYRA-465)" do
    def event_option(body, value) = Nokogiri::HTML(body).at_css("option[value='#{value}']")

    it "non è proponibile quando nessuna macchina riporta la temperatura" do
      get new_member_alerting_rule_path

      expect(event_option(response.body, "server_temp")).to be_nil
      # gli altri eventi server restano: si nasconde solo quello impossibile
      expect(event_option(response.body, "server_cpu")).not_to be_nil
    end

    it "diventa proponibile appena una macchina della flotta la riporta" do
      host = create(:server_host, organization: org)
      create(:server_sample, host: host, temp_max: 48.5)

      get new_member_alerting_rule_path

      expect(event_option(response.body, "server_temp")).not_to be_nil
    end

    it "resta selezionabile in modifica di una regola già impostata su di esso" do
      rule = create(:alerting_rule, organization: org, event_type: :server_temp, threshold: 80)

      get edit_member_alerting_rule_path(rule)

      expect(event_option(response.body, "server_temp")).not_to be_nil
    end
  end

  it "il campo del raggruppamento non si chiama più «Throttle»" do
    get new_member_alerting_rule_path

    expect(I18n.t("member.alerting.rules.form.throttle")).not_to eq("Throttle")
    expect(response.body).to include(I18n.t("member.alerting.rules.form.throttle"))
  end

  # CYRA-496 — senza canali esterni il campo «Canali esterni» era una tendina vuota sotto un aiuto che
  # parlava di canali inesistenti: la domanda vera («e allora dove arrivano gli avvisi?») restava senza
  # risposta, scritta solo dentro la pagina dei canali. È la stessa frase dell'elenco vuoto.
  describe "dove arrivano gli avvisi quando non c'è nessun canale esterno (CYRA-496)" do
    it "lo dice sotto il campo, con la frase dell'elenco vuoto" do
      get new_member_alerting_rule_path

      expect(field(response.body, "alerting-rule-channels").text).to include(I18n.t("member.alerting.channels.empty"))
    end

    it "con un canale collegabile torna l'aiuto che spiega cosa fa la scelta" do
      # Il model risolve il DNS della URL del webhook: qui la risposta è finta, la rete non si tocca.
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      create(:alerting_channel, organization: org, name: "Ops webhook")

      get new_member_alerting_rule_path

      testo = field(response.body, "alerting-rule-channels").text
      expect(testo).to include(I18n.t("member.alerting.rules.form.channels_hint"))
      expect(testo).not_to include(I18n.t("member.alerting.channels.empty"))
    end
  end
end
