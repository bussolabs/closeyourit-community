# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectSettings", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }
  let(:project) { create(:project, organization: org) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET show (tab Settings)" do
    it "owner → 200 con il campo retention e l'effettiva" do
      sign_in(owner)
      get member_project_settings_path(project)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("logs-retention-days")
      expect(response.body).to include("project-settings-effective")
    end

    it "member non assegnato → 404 (progetto non visibile, anti-BOLA)" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      sign_in(member)
      get member_project_settings_path(project)
      expect(response).to have_http_status(:not_found)
    end

    it "owner → mostra la select dell'assegnatario di default dei ticket" do
      sign_in(owner)
      get member_project_settings_path(project)
      expect(response.body).to include("project-default-assignee")
    end

    # CYRA-341 — la soglia che colora le durate non era scritta da nessuna parte: ora si legge e si cambia.
    it "owner → mostra i campi delle soglie di durata con quelle in vigore" do
      sign_in(owner)
      get member_project_settings_path(project)

      expect(response.body).to include("performance-fast-ms")
      expect(response.body).to include("performance-slow-ms")
      expect(response.body).to include("project-settings-thresholds-effective")
    end

    it "owner → mostra il campo origin allowlist del public ingest (CYRA-109)" do
      sign_in(owner)
      get member_project_settings_path(project)
      expect(response.body).to include("project-allowed-origins")
    end

    # CYRA-376 — la registrazione delle sessioni si accende per progetto, ma l'interruttore non
    # esisteva in nessuna schermata: la funzione si poteva solo scoprire e non attivare.
    it "sui progetti con una piattaforma web mostra l'interruttore delle registrazioni" do
      project.platforms << create(:platform, organization: org, supports_session_replay: true)
      sign_in(owner)
      get member_project_settings_path(project)

      expect(response.body).to include("project-session-replay-toggle")
    end

    it "senza piattaforma web l'interruttore non compare: non avrebbe effetto" do
      sign_in(owner)
      get member_project_settings_path(project)

      expect(response.body).not_to include("project-session-replay-toggle")
    end

    # CYRA-563 — la pagina è lunga tre schermate e il Salva stava solo in cima: chi compilava
    # l'ultimo campo doveva risalire due schermate per trovarlo. E gli interruttori, che invece
    # si salvano da soli, erano identici a occhio ai campi che il Salva aspettano.
    describe "i due modi di salvare si distinguono (CYRA-563)" do
      def page_doc
        sign_in(owner)
        get member_project_settings_path(project)
        Nokogiri::HTML(response.body)
      end

      # Each panel is shown on its own (the side menu switches them), so each one carries its own form
      # and its own Save in the panel header: no shared bar that saves fields the person cannot see.
      %w[ingest tickets retention thresholds].each do |anchor|
        it "the #{anchor} panel is its own form, with a Save in its header" do
          form = page_doc.at_css("[data-test='project-settings-form-#{anchor}']")

          expect(form).to be_present
          expect(form.at_css("##{anchor}")).to be_present
          submit = form.at_css("##{anchor} [data-test='project-settings-submit-#{anchor}']")
          expect(submit).to be_present
          expect(submit["type"]).to eq("submit")
          expect(form.at_css("input[type='hidden'][name='section'][value='#{anchor}']")).to be_present
        end
      end

      it "there is no shared save bar any more" do
        expect(page_doc.at_css("[data-test='project-settings-save-bar']")).to be_nil
      end

      it "the side menu switches one panel at a time, each panel named after its anchor" do
        doc = page_doc
        container = doc.at_css("[data-controller~='section-panels']")
        anchors = container.css("[data-section-panels-target='panel']").map { |node| node["data-anchor"] }
        links = doc.css("[data-test='project-settings-nav'] a").map { |a| a["href"].delete_prefix("#") }

        expect(anchors).to eq(links)
      end

      it "la card delle funzionalità dichiara che gli interruttori si applicano subito" do
        avviso = page_doc.at_css("[data-test='project-features-hint']")

        expect(avviso).to be_present
        expect(avviso.text).to include(I18n.t("member.project_settings.features_hint"))
      end

      it "gli interruttori restano fuori dal form: il Salva non li riguarda" do
        doc = page_doc

        expect(doc.at_css("[data-test='project-features']")).to be_present
        expect(doc.at_css("form [data-test='project-features']")).to be_nil
      end

      # CYRA-856 — gli interruttori partono dallo stato del progetto: se aria-checked non lo
      # seguisse, la pagina mostrerebbe spento ciò che è acceso (e un lettore di schermo pure).
      it "i tre interruttori partono spenti quando il progetto li ha spenti" do
        project.update!(quick_bug_report_enabled: false, analytics_enabled: false,
                        secret_approval_enabled: false)
        doc = page_doc

        expect(doc.at_css("[data-test='project-roadmap-toggle']")).to be_nil
        %w[quick-bug-report analytics secret-approval].each do |interruttore|
          nodo = doc.at_css("button[data-test='project-#{interruttore}-toggle']")
          expect(nodo["role"]).to eq("switch")
          expect(nodo["aria-checked"]).to eq("false")
        end
      end

      it "riflette lo stato invertito dei flag" do
        project.update!(quick_bug_report_enabled: true, analytics_enabled: true,
                        secret_approval_enabled: true)
        doc = page_doc

        %w[quick-bug-report analytics secret-approval].each do |interruttore|
          expect(doc.at_css("button[data-test='project-#{interruttore}-toggle']")["aria-checked"]).to eq("true")
        end
      end
    end
  end

  describe "PATCH update" do
    before { sign_in(owner) }

    it "salva l'override per-progetto" do
      patch member_project_settings_path(project), params: { logs_retention_days: 7 }
      expect(response).to redirect_to(member_project_settings_path(project))
      expect(project.reload.logs_retention_days).to eq(7)
    end

    it "un valore blank azzera l'override (eredita)" do
      project.update!(logs_retention_days: 7)
      patch member_project_settings_path(project), params: { logs_retention_days: "" }
      expect(project.reload.logs_retention_days).to be_nil
    end

    it "rifiuta un valore fuori da 1..365 → 422" do
      patch member_project_settings_path(project), params: { logs_retention_days: 0 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "salva gli override per-progetto errori/performance/uptime (CYRA-159)" do
      patch member_project_settings_path(project),
            params: { errors_retention_days: 90, performance_retention_days: 60, uptime_retention_days: 365 }
      expect(response).to redirect_to(member_project_settings_path(project))
      project.reload
      expect(project.errors_retention_days).to eq(90)
      expect(project.performance_retention_days).to eq(60)
      expect(project.uptime_retention_days).to eq(365)
    end

    it "rifiuta uptime fuori da 1..730 → 422" do
      patch member_project_settings_path(project), params: { uptime_retention_days: 999 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "BOLA: progetto di un'altra org → 404" do
      foreign = create(:project)
      patch member_project_settings_path(foreign), params: { logs_retention_days: 7 }
      expect(response).to have_http_status(:not_found)
    end

    # CYRA-341 — le soglie che colorano le durate diventano un'impostazione del progetto.
    it "salva le soglie di durata del progetto" do
      patch member_project_settings_path(project),
            params: { performance_fast_ms: 80, performance_slow_ms: 900 }

      expect(response).to redirect_to(member_project_settings_path(project))
      project.reload
      expect(project.performance_fast_ms).to eq(80)
      expect(project.performance_slow_ms).to eq(900)
    end

    it "una soglia blank torna al valore di sistema" do
      project.update!(performance_fast_ms: 80, performance_slow_ms: 900)

      patch member_project_settings_path(project),
            params: { performance_fast_ms: "", performance_slow_ms: "" }

      project.reload
      expect(project.performance_fast_ms).to be_nil
      expect(Metrics::Thresholds.for(project)).to eq(fast: Metrics::Group::FAST_MS, slow: Metrics::Group::MEDIUM_MS)
    end

    it "rifiuta una soglia veloce oltre quella lenta → 422" do
      patch member_project_settings_path(project),
            params: { performance_fast_ms: 900, performance_slow_ms: 300 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(project.reload.performance_fast_ms).to be_nil
    end

    it "rifiuta una soglia non positiva → 422" do
      patch member_project_settings_path(project), params: { performance_slow_ms: 0 }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "salva l'assegnatario di default dei ticket" do
      assignee = create(:account)
      create(:membership, account: assignee, organization: org, role: :member)
      patch member_project_settings_path(project), params: { default_assignee_id: assignee.id }
      expect(response).to redirect_to(member_project_settings_path(project))
      expect(project.reload.default_assignee).to eq(assignee)
    end

    it "un default_assignee blank azzera l'assegnatario di default (eredita)" do
      assignee = create(:account)
      create(:membership, account: assignee, organization: org, role: :member)
      project.update!(default_assignee: assignee)
      patch member_project_settings_path(project), params: { default_assignee_id: "" }
      expect(project.reload.default_assignee).to be_nil
    end

    it "rifiuta un default_assignee non membro dell'org → 422" do
      outsider = create(:account)
      patch member_project_settings_path(project), params: { default_assignee_id: outsider.id }
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.reload.default_assignee).to be_nil
    end

    it "salva l'origin allowlist del public ingest (una origine per riga, CYRA-109)" do
      patch member_project_settings_path(project),
            params: { allowed_origins: "https://app.example\nhttps://www.example.com" }
      expect(response).to redirect_to(member_project_settings_path(project))
      expect(project.reload.allowed_origins).to eq(%w[https://app.example https://www.example.com])
    end

    it "un'allowlist blank azzera il vincolo di provenienza" do
      project.update!(allowed_origins: [ "https://app.example" ])
      patch member_project_settings_path(project), params: { allowed_origins: "" }
      expect(project.reload.allowed_origins).to eq([])
    end

    it "rifiuta un'origine malformata → 422, nessuna modifica" do
      patch member_project_settings_path(project), params: { allowed_origins: "non-un-origine" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.reload.allowed_origins).to eq([])
    end
  end

  describe "gate projects.edit (visibile ma senza permesso)" do
    it "member assegnato al progetto ma senza projects.edit → bloccato, nessuna modifica" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, account: member, project: project) # lo VEDE (scoping ok)
      sign_in(member)

      patch member_project_settings_path(project), params: { logs_retention_days: 9 }

      expect(response).to redirect_to(root_path) # gate require_permission!, non 404
      expect(project.reload.logs_retention_days).to be_nil
    end
  end

  # Switch auto-save (fetch PATCH dal controller Stimulus ui--switch): formato JSON → 204, niente redirect.
  describe "PATCH update — switch funzionalità (JSON)" do
    before { sign_in(owner) }

    it "quick_bug_report_enabled '1' → 204 e attiva il flag" do
      project.update!(quick_bug_report_enabled: false)
      patch member_project_settings_path(project), params: { quick_bug_report_enabled: "1" }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(project.reload.quick_bug_report_enabled?).to be(true)
    end

    it "analytics_enabled '1' → 204 e attiva la raccolta analytics" do
      expect(project.analytics_enabled?).to be(false) # default opt-in
      patch member_project_settings_path(project), params: { analytics_enabled: "1" }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(project.reload.analytics_enabled?).to be(true)
    end

    it "switches the help desk on for the project (CYRA-940)" do
      patch member_project_settings_path(project), params: { helpdesk_enabled: "1" }, as: :json
      expect(project.reload.helpdesk_enabled?).to be(true)
    end

    it "analytics_enabled '0' → 204 e disattiva la raccolta analytics" do
      project.update!(analytics_enabled: true)
      patch member_project_settings_path(project), params: { analytics_enabled: "0" }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(project.reload.analytics_enabled?).to be(false)
    end

    # CYRA-376 — l'interruttore è la strada che l'invito nella pagina delle sessioni promette.
    it "session_replay_enabled '1' → 204 e accende la registrazione delle sessioni" do
      expect(project.session_replay_enabled?).to be(false) # default opt-in
      patch member_project_settings_path(project), params: { session_replay_enabled: "1" }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(project.reload.session_replay_enabled?).to be(true)
    end

    it "session_replay_enabled '0' → 204 e spegne la registrazione delle sessioni" do
      project.update!(session_replay_enabled: true)
      patch member_project_settings_path(project), params: { session_replay_enabled: "0" }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(project.reload.session_replay_enabled?).to be(false)
    end

    it "secret_approval_enabled '1' → 204 e attiva l'approvazione in due (CYRA-138)" do
      project.update!(secret_approval_enabled: false)
      patch member_project_settings_path(project), params: { secret_approval_enabled: "1" }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(project.reload.secret_approval_enabled?).to be(true)
    end

    it "secret_approval_enabled '0' → 204 e disattiva l'approvazione in due" do
      project.update!(secret_approval_enabled: true)
      patch member_project_settings_path(project), params: { secret_approval_enabled: "0" }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(project.reload.secret_approval_enabled?).to be(false)
    end

    it "toggle ripetuto on→off→on resta coerente (confine stato)" do
      project.update!(quick_bug_report_enabled: false)
      patch member_project_settings_path(project), params: { quick_bug_report_enabled: "1" }, as: :json
      expect(project.reload.quick_bug_report_enabled?).to be(true)
      patch member_project_settings_path(project), params: { quick_bug_report_enabled: "0" }, as: :json
      expect(project.reload.quick_bug_report_enabled?).to be(false)
      patch member_project_settings_path(project), params: { quick_bug_report_enabled: "1" }, as: :json
      expect(project.reload.quick_bug_report_enabled?).to be(true)
    end

    it "un solo flag nel body non tocca l'altro" do
      project.update!(analytics_enabled: true, quick_bug_report_enabled: false)
      patch member_project_settings_path(project), params: { quick_bug_report_enabled: "1" }, as: :json
      expect(project.reload.quick_bug_report_enabled?).to be(true)
      expect(project.analytics_enabled?).to be(true) # invariato
    end

    it "persiste anche se il progetto ha un campo non correlato invalido (record legacy)" do
      project.update_columns(key: "TOOLONG", quick_bug_report_enabled: false) # forza stato invalido (key max 4) bypassando la validazione
      expect(project.reload).not_to be_valid

      patch member_project_settings_path(project), params: { quick_bug_report_enabled: "1" }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(project.reload.quick_bug_report_enabled?).to be(true)
    end

    it "body senza un flag conosciuto → 422 (niente da togglare)" do
      patch member_project_settings_path(project), params: { pippo: "1" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "BOLA: toggle su progetto di un'altra org → 404" do
      foreign = create(:project)
      patch member_project_settings_path(foreign), params: { quick_bug_report_enabled: "1" }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "senza projects.edit il toggle non modifica nulla" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, account: member, project: project)
      project.update!(quick_bug_report_enabled: false)
      sign_in(member)

      patch member_project_settings_path(project), params: { quick_bug_report_enabled: "1" }, as: :json

      expect(project.reload.quick_bug_report_enabled?).to be(false)
    end
  end

  describe "saving one panel returns to that panel" do
    it "redirects back to the panel that was saved" do
      sign_in(owner)
      patch member_project_settings_path(project), params: { logs_retention_days: 7, section: "retention" }

      expect(response).to redirect_to(member_project_settings_path(project, section: "retention"))
    end

    it "ignores a section that is not a panel of the page" do
      sign_in(owner)
      patch member_project_settings_path(project), params: { logs_retention_days: 7, section: "evil" }

      expect(response).to redirect_to(member_project_settings_path(project))
    end

    it "the page it lands on opens that panel" do
      sign_in(owner)
      get member_project_settings_path(project, section: "retention")

      container = Nokogiri::HTML(response.body).at_css("[data-controller~='section-panels']")
      expect(container["data-section-panels-initial-value"]).to eq("retention")
    end

    it "an invalid save opens the same panel again, with its error" do
      sign_in(owner)
      patch member_project_settings_path(project), params: { logs_retention_days: 0, section: "retention" }

      expect(response).to have_http_status(:unprocessable_content)
      container = Nokogiri::HTML(response.body).at_css("[data-controller~='section-panels']")
      expect(container["data-section-panels-initial-value"]).to eq("retention")
    end
  end
end
