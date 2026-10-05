# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::AlertingRules", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    create(:membership, account: member, organization: organization, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect al login" do
      get member_alerting_rules_path
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200" do
      sign_in(owner)
      create(:alerting_rule, organization: organization, name: "Any new error")
      get member_alerting_rules_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Any new error")
    end

    # CYRA-476: la riga apre la pagina della regola (show), da cui si vede cosa copre e si va a modificarla.
    # E11 — "5m" under Grouping is explained on the column header.
    it "explains the Grouping column on its header" do
      sign_in(owner)
      create(:alerting_rule, organization: organization, name: "Any new error")
      get member_alerting_rules_path

      expect(response.body).to include('data-test="alerting-col-throttle-hint"')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.alerting.rules.form.throttle_hint")))
    end

    # F109 — C14: the row says the condition, not only the event and the scope.
    it "writes the rule condition on its row" do
      cpu = create(:alerting_rule, organization:, event_type: :server_cpu, threshold: 85)
      plain = create(:alerting_rule, organization:, event_type: :uptime_down)
      sign_in(owner)

      get member_alerting_rules_path

      html = Capybara.string(response.body)
      expect(html.find("[data-test='alerting-rule-condition-#{cpu.id}']").text).to eq("> 85%")
      expect(html).to have_no_css("[data-test='alerting-rule-condition-#{plain.id}']")
    end

    it "la riga della regola linka alla sua pagina (show)" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization, name: "Linked")
      get member_alerting_rules_path
      expect(response.body).to include(member_alerting_rule_path(rule))
    end

    it "member senza alerts.manage → redirect (forbidden)" do
      sign_in(member)
      get member_alerting_rules_path
      expect(response).to redirect_to(root_path)
    end

    # CYRA-55: le regole log_alert usano min_level come gli errori → la index deve mostrarlo (prima
    # era gated sul solo error_event?, incoerente con Alerting::Evaluate#level_match?). Lo stesso ramo
    # usava ::Alerting::Rule.levels (metodo inesistente: l'enum è event_type, la costante è LEVELS) →
    # crash 500 con QUALSIASI min_level valorizzato, latente perché nessun test lo esercitava.
    it "mostra il livello minimo per una regola error (non crasha su min_level)" do
      sign_in(owner)
      create(:alerting_rule, organization: organization, event_type: :error_new,
                             name: "Fatal errors", min_level: Errors::Group.levels["fatal"])
      get member_alerting_rules_path
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      row = doc.at_css("[data-test='alerting-rule-row']")
      expect(row.text).to include("#{I18n.t('member.alerting.rules.form.min_level')} ≥")
      expect(row.text).to include(I18n.t("member.alerting.levels.fatal"))
    end

    it "mostra il livello minimo anche per una regola log_alert" do
      sign_in(owner)
      create(:alerting_rule, organization: organization, event_type: :log_alert,
                             name: "Fatal logs", min_level: Logs::Entry.levels["fatal"])
      get member_alerting_rules_path
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      row = doc.at_css("[data-test='alerting-rule-row']")
      expect(row.text).to include("#{I18n.t('member.alerting.rules.form.min_level')} ≥")
      expect(row.text).to include(I18n.t("member.alerting.levels.fatal"))
    end
  end

  describe "GET new" do
    it "owner → 200" do
      sign_in(owner)
      get new_member_alerting_rule_path
      expect(response).to have_http_status(:ok)
    end

    it "member → redirect" do
      sign_in(member)
      get new_member_alerting_rule_path
      expect(response).to redirect_to(root_path)
    end

    # CYRA-477: il link "Crea la regola" dalle index cron/uptime apre il form già sull'evento scoperto.
    it "prefilla l'evento dal parametro (link 'crea la regola')" do
      sign_in(owner)
      get new_member_alerting_rule_path(event_type: "cron_missed")
      expect(response).to have_http_status(:ok)
      # CYRA-481: la tendina ora è raggruppata per famiglia e l'ordine degli attributi cambia — si
      # chiede al DOM qual è l'opzione selezionata, non alla stringa.
      selected = Nokogiri::HTML(response.body).at_css("[data-test='alerting-rule-event-select'] option[selected]")
      expect(selected["value"]).to eq("cron_missed")
    end

    it "ignora un evento non valido senza crashare (form pulito)" do
      sign_in(owner)
      get new_member_alerting_rule_path(event_type: "not_a_real_event")
      expect(response).to have_http_status(:ok)
    end

    # CYRA-476: dal detail di un monitor il link porta anche progetto+ambiente → regola già mirata al sito.
    it "prefilla progetto e ambiente dai parametri (link dal detail del monitor)" do
      sign_in(owner)
      project = create(:project, organization: organization)
      env = create(:environment, organization: organization)
      get new_member_alerting_rule_path(event_type: "uptime_down", project_id: project.id, environment_id: env.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/value="#{Regexp.escape(project.id)}"[^>]*selected/)
      expect(response.body).to match(/value="#{Regexp.escape(env.id)}"[^>]*selected/)
    end

    it "ignora un progetto estraneo (non visibile) nel prefill" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      get new_member_alerting_rule_path(event_type: "uptime_down", project_id: foreign.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to match(/value="#{Regexp.escape(foreign.id)}"[^>]*selected/)
    end

    it "i label delle soglie sono associati ai rispettivi input via for/id (a11y)" do
      sign_in(owner)
      get new_member_alerting_rule_path
      doc = Nokogiri::HTML(response.body)
      %w[threshold_ms threshold throttle_minutes].each do |field|
        expect(doc.at_css("label[for='#{field}']")).to be_present, "manca <label for=\"#{field}\">"
        expect(doc.at_css("##{field}")).to be_present, "manca <input id=\"#{field}\">"
      end
      # Lo heading "Status" non è più un <label> orfano (nessun for/wrapping) — evita doppia
      # associazione con la checkbox enabled.
      expect(doc.css("label").map { |l| l.text.strip }).not_to include(I18n.t("member.alerting.rules.form.status"))
    end
  end

  describe "POST create" do
    it "owner crea una regola (throttle minuti → secondi)" do
      sign_in(owner)
      expect do
        post member_alerting_rules_path, params: {
          name: "Prod errors", event_type: "error_new", throttle_minutes: 5, enabled: "1"
        }
      end.to change(::Alerting::Rule, :count).by(1)
      rule = ::Alerting::Rule.last
      expect(rule.throttle_seconds).to eq(300)
      expect(rule.created_by).to eq(owner)
      expect(response).to redirect_to(member_alerting_rules_path)
    end

    it "nome vuoto → 422, niente creazione" do
      sign_in(owner)
      expect do
        post member_alerting_rules_path, params: { name: "", event_type: "error_new", throttle_minutes: 5 }
      end.not_to change(::Alerting::Rule, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    # CYRA-477 Scenario 3: creando la regola "cron mancato" dal banner, i job già fermi vengono avvisati.
    it "creando una regola cron_missed avvisa i cron già fermi" do
      sign_in(owner)
      project = create(:project, organization: organization)
      missed = create(:cron_monitor, project:, status: :missed, last_check_in_at: 3.days.ago)

      expect do
        post member_alerting_rules_path, params: {
          name: "Job mancati", event_type: "cron_missed", throttle_minutes: 5, enabled: "1"
        }
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "cron_missed", subject_id: missed.id))
      expect(response).to redirect_to(member_alerting_rules_path)
    end

    # CYRA-49: alert configurabile sui soli errori non-gestiti.
    it "owner crea una regola unhandled_only (checkbox=1)" do
      sign_in(owner)
      post member_alerting_rules_path, params: {
        name: "Only crashes", event_type: "error_new", throttle_minutes: 5, unhandled_only: "1"
      }
      expect(::Alerting::Rule.last.unhandled_only).to be(true)
    end

    it "unhandled_only di default falso (checkbox=0)" do
      sign_in(owner)
      post member_alerting_rules_path, params: {
        name: "Any error", event_type: "error_new", throttle_minutes: 5, unhandled_only: "0"
      }
      expect(::Alerting::Rule.last.unhandled_only).to be(false)
    end

    it "owner crea una regola metric_threshold con soglia di durata (threshold_ms)" do
      sign_in(owner)
      post member_alerting_rules_path, params: {
        name: "Slow stuff", event_type: "metric_threshold", throttle_minutes: 5, threshold_ms: "750"
      }
      expect(::Alerting::Rule.last.threshold_ms).to eq(750)
    end

    it "threshold_ms vuoto → salvato come nil (nessuna soglia)" do
      sign_in(owner)
      post member_alerting_rules_path, params: {
        name: "Any perf", event_type: "metric_threshold", throttle_minutes: 5, threshold_ms: ""
      }
      expect(::Alerting::Rule.last.threshold_ms).to be_nil
    end

    it "member → niente creazione, redirect" do
      sign_in(member)
      expect do
        post member_alerting_rules_path, params: { name: "X", event_type: "error_new", throttle_minutes: 5 }
      end.not_to change(::Alerting::Rule, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  # CYRA-476: la pagina della regola elenca le cose che sorveglia oggi, col conteggio.
  describe "GET show" do
    it "il raggruppo si legge in minuti scritti per esteso, non «5m»" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization, throttle_seconds: 300)

      get member_alerting_rule_path(rule)

      chip = Nokogiri::HTML(response.body).at_css("[data-test='alerting-rule-throttle']").text
      expect(chip).to include(I18n.t("member.alerting.rules.show.sentence.minutes", count: 5))
      expect(chip).not_to include("5m")
    end

    it "non gestore (member) → redirect (forbidden)" do
      sign_in(member)
      rule = create(:alerting_rule, organization: organization)
      get member_alerting_rule_path(rule)
      expect(response).to redirect_to(root_path)
    end

    it "anti-BOLA: regola di un'altra org → 404" do
      sign_in(owner)
      other = create(:alerting_rule, organization: create(:organization))
      get member_alerting_rule_path(other)
      expect(response).to have_http_status(:not_found)
    end

    it "una regola uptime elenca i siti coperti col conteggio e link alla modifica" do
      sign_in(owner)
      project = create(:project, organization: organization)
      monitor = create(:uptime_monitor, project:)
      rule = create(:alerting_rule, :uptime_down, organization: organization, name: "Produzione giù")

      get member_alerting_rule_path(rule)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="alerting-rule-coverage"')
      expect(response.body).to include(ERB::Util.html_escape(monitor.name))
      expect(response.body).to include(member_monitoring_monitor_path(monitor))
      expect(response.body).to include(edit_member_alerting_rule_path(rule))
    end

    it "una regola errore elenca i progetti coperti" do
      sign_in(owner)
      project = create(:project, organization: organization, name: "Alpha")
      rule = create(:alerting_rule, organization: organization, event_type: :error_new)

      get member_alerting_rule_path(rule)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="alerting-rule-coverage"')
      expect(response.body).to include("Alpha")
    end

    it "una regola org-scoped dichiara che copre l'intera organizzazione" do
      sign_in(owner)
      rule = create(:alerting_rule, :server_down, organization: organization)

      get member_alerting_rule_path(rule)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="alerting-rule-coverage-org"')
    end

    it "una regola cron_missed elenca i lavori programmati coperti con link" do
      sign_in(owner)
      project = create(:project, organization: organization)
      cron = create(:cron_monitor, project:, name: "Backup notturno")
      rule = create(:alerting_rule, organization: organization, event_type: :cron_missed)

      get member_alerting_rule_path(rule)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Backup notturno")
      expect(response.body).to include(member_monitoring_cron_monitor_path(cron))
    end

    # CYRA-490: la condizione è scritta in una frase comprensibile, generata dai campi della regola.
    it "mostra la condizione in una frase leggibile" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization, event_type: :error_new)

      get member_alerting_rule_path(rule)

      expect(response).to have_http_status(:ok)
      body = Nokogiri::HTML(response.body).at_css("[data-test='alerting-rule-sentence-body']")
      expect(body).to be_present
      expect(body.text).to include(::Notifications::Catalog.entry("error_new").description)
    end

    # CYRA-490: lo storico degli scatti — quante volte è scattata e su che cosa.
    it "mostra lo storico degli scatti con l'ultimo avviso prodotto" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization, event_type: :error_new)
      create(:alerting_notification, rule:, organization:, title: "Nuovo errore · Boom", created_at: 30.minutes.ago)

      get member_alerting_rule_path(rule)

      expect(response).to have_http_status(:ok)
      history = Nokogiri::HTML(response.body).at_css("[data-test='alerting-rule-history']")
      expect(history).to be_present
      expect(history.text).to include("Nuovo errore · Boom")
    end

    it "lo storico è presente ma vuoto quando la regola non è mai scattata" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization)

      get member_alerting_rule_path(rule)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="alerting-rule-history"')
      expect(response.body).to include('data-test="alerting-rule-history-empty"')
    end
  end

  describe "GET edit" do
    it "owner → 200" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization)
      get edit_member_alerting_rule_path(rule)
      expect(response).to have_http_status(:ok)
    end

    it "anti-BOLA: regola di un'altra org → 404" do
      sign_in(owner)
      other = create(:alerting_rule, organization: create(:organization))
      get edit_member_alerting_rule_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    it "owner aggiorna nome e disattiva" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization, name: "Old")
      patch member_alerting_rule_path(rule), params: { name: "New", event_type: rule.event_type, throttle_minutes: 10, enabled: "0" }
      expect(rule.reload.name).to eq("New")
      expect(rule.enabled).to be(false)
      expect(rule.throttle_seconds).to eq(600)
    end

    it "update SENZA throttle_minutes → mantiene il throttle esistente (ramo else)" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization, name: "Keep", throttle_seconds: 300)
      patch member_alerting_rule_path(rule), params: { name: "Renamed", event_type: rule.event_type, enabled: "1" }
      expect(rule.reload.name).to eq("Renamed")
      expect(rule.throttle_seconds).to eq(300)
    end
  end

  describe "DELETE destroy" do
    it "owner elimina" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization)
      expect { delete member_alerting_rule_path(rule) }.to change(::Alerting::Rule, :count).by(-1)
      expect(response).to redirect_to(member_alerting_rules_path)
    end
  end

  describe "filtri e scope completo" do
    it "index filtra per q, event_type e progetto" do
      sign_in(owner)
      project = create(:project, organization: organization)
      create(:alerting_rule, organization: organization, name: "Prod alpha", event_type: :error_new, project: project)
      create(:alerting_rule, organization: organization, name: "Other noise", event_type: :uptime_down)
      get member_alerting_rules_path, params: { q: "alpha", event_type: [ "error_new" ], project_id: [ project.id ] }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Prod alpha")
      expect(response.body).not_to include("Other noise")
    end

    it "create con scope progetto + environment + min_level valorizzati" do
      sign_in(owner)
      project = create(:project, organization: organization)
      env = create(:environment, organization: organization)
      post member_alerting_rules_path, params: {
        name: "Scoped", event_type: "error_new", throttle_minutes: 10, enabled: "1",
        project_id: project.id, environment_id: env.id, min_level: ::Errors::Group.levels["error"]
      }
      rule = ::Alerting::Rule.last
      expect(rule.project_id).to eq(project.id)
      expect(rule.environment_id).to eq(env.id)
      expect(rule.min_level).to eq(::Errors::Group.levels["error"])
    end

    it "update con nome vuoto → 422" do
      sign_in(owner)
      rule = create(:alerting_rule, organization: organization)
      patch member_alerting_rule_path(rule), params: { name: "", event_type: rule.event_type, throttle_minutes: 5 }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # CYRA-26: the form note (at the bottom, hand-drawn with an info icon) moves to the
  # title_tip bulb next to the form title.
  describe "nota del form nel bulb title_tip (CYRA-26)" do
    before { sign_in(owner) }

    # CYRA-883 — the form note is the header subtitle.
    it "shows the form note as the header subtitle" do
      get new_member_alerting_rule_path
      subtitle = Nokogiri::HTML(response.body).at_css("[data-test='alerting-rule-header-subtitle']")
      expect(subtitle.text).to include(I18n.t("member.alerting.rules.form.note"))
    end

    it "no longer renders the hand-drawn note (info icon) at the bottom of the form" do
      get new_member_alerting_rule_path
      expect(Nokogiri::HTML(response.body).css("svg[data-icon='info']")).to be_empty
    end
  end
end
