# frozen_string_literal: true

require "rails_helper"

# CYRA-501 — la raccolta di guide promette «i passi esatti per configurarla» e poi, sul passo che
# conta, dice di inserire nel proprio sito un codice che non mostra; e la parte da cui dipende il
# valore del prodotto — le macchine che lavorano i ticket — non aveva nessuna guida: cosa significa
# un lavoro respinto, quando arriva una richiesta di approvazione e cosa succede se non si risponde
# non si scoprono da soli.
RSpec.describe "Member — guide di automazione e statistiche (CYRA-501)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  # Progetto che RACCOGLIE analytics: piattaforma web (capable) + toggle "Raccogli analytics" attivo.
  let(:project) { create(:project, organization: org, name: "Sito vetrina", analytics_enabled: true).tap { |p| p.platforms << web } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def page
    Nokogiri::HTML(response.body)
  end

  # Scenario 1 del ticket: il passo che chiede di inserire il codice nel proprio sito deve mostrarlo,
  # già compilato per il progetto scelto, con un pulsante per copiarlo.
  describe "la guida delle statistiche mostra il codice da installare" do
    it "stampa lo snippet compilato per il progetto scelto, con il pulsante per copiarlo" do
      create(:project_token, project:, public_key: "a" * 32)
      sign_in(owner)

      get member_guides_analytics_path

      expect(response).to have_http_status(:ok)
      snippet = page.at_css("[data-test='guide-analytics-snippet']")
      expect(snippet).to be_present
      expect(snippet.text).to include(project.id)
      expect(snippet.text).to include("a" * 32)
      expect(snippet.text).to include("trackPageviews: true")
      expect(page.at_css("[data-test='guide-analytics-copy']")).to be_present
    end

    it "si sceglie il progetto, e la scelta cambia il codice mostrato" do
      altro = create(:project, organization: org, name: "Blog", analytics_enabled: true).tap { |p| p.platforms << web }
      create(:project_token, project: altro, public_key: "b" * 32)
      sign_in(owner)

      get member_guides_analytics_path(project_id: altro.id)

      expect(page.at_css("[data-test='guide-analytics-project-picker']")).to be_present
      expect(page.at_css("[data-test='guide-analytics-snippet']").text).to include(altro.id)
      expect(page.at_css("[data-test='guide-analytics-snippet']").text).to include("b" * 32)
    end

    # Anti-BOLA: un progetto di un'altra organizzazione (o un id inventato) non deve né comparire né
    # far esplodere una pagina di sola lettura.
    it "un progetto non visibile non svuota la pagina: torna al primo che si può leggere" do
      estraneo = create(:project, analytics_enabled: true)
      project
      sign_in(owner)

      get member_guides_analytics_path(project_id: estraneo.id)

      expect(response).to have_http_status(:ok)
      expect(page.at_css("[data-test='guide-analytics-snippet']").text).to include(project.id)
    end

    # La chiave pubblica è una credenziale di ingest e la sua pagina sta dietro tokens.manage: la
    # guida la legge chiunque, quindi qui vale lo stesso confine della pagina delle statistiche.
    it "a chi non gestisce i codici mostra il segnaposto, mai la chiave vera" do
      create(:project_token, project:, public_key: "c" * 32)
      create(:project_membership, account: member, project:)
      sign_in(member)

      get member_guides_analytics_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("c" * 32)
      expect(page.at_css("[data-test='guide-analytics-snippet']").text)
        .to include(I18n.t("member.monitoring.analytics.onboarding.key_placeholder"))
      expect(page.at_css("[data-test='guide-analytics-token-locked']")).to be_present
    end

    it "senza un progetto che raccoglie statistiche la guida resta leggibile, con l'esempio" do
      sign_in(owner)

      get member_guides_analytics_path

      expect(response).to have_http_status(:ok)
      expect(page.at_css("[data-test='guide-analytics-project-picker']")).to be_nil
      expect(page.at_css("[data-test='guide-analytics-snippet']").text).to include("CloseYourIt.init")
      expect(page.at_css("[data-test='guide-analytics-no-project']")).to be_present
    end

    # CYRA-542 — il codice suggerito chiedeva «l'ultima versione», quindi una pubblicazione nuova
    # arrivava da sola su ogni sito già installato: qui la versione la dichiara chi copia.
    it "il codice da incollare dichiara la versione dello script" do
      sign_in(owner)

      get member_guides_analytics_path

      snippet = page.at_css("[data-test='guide-analytics-snippet']").text
      expect(snippet).to include("@bussolabs/closeyourit-js@0/dist/closeyourit.min.js")
      expect(snippet).not_to include("@bussolabs/closeyourit-js/dist")
    end
  end

  # Scenario 2 del ticket: chi vuole capire come lavorano le macchine deve trovare una guida
  # dedicata, e raggiungerla anche dalla pagina delle macchine e dalla coda delle decisioni.
  describe "la guida su come lavorano gli agenti" do
    before { sign_in(owner) }

    # CYRA-631 — i passaggi sono quelli del MODELLO, non le fasi interne della macchina: sono le sei
    # parole che si leggono sul ticket e sulla plancia, e vengono da lì. La guida non tiene più un
    # elenco suo.
    it "racconta il ciclo di lavoro, un passaggio per volta e con le parole dell'interfaccia" do
      get member_guides_agents_path

      expect(response).to have_http_status(:ok)
      ciclo = page.at_css("[data-test='member-guide-agents-cycle']")
      expect(ciclo).to be_present
      Agents::Workflows::PhaseResolver::STEPS.each do |step|
        expect(ciclo.at_css("[data-test='guide-agents-step-#{step}']")).to be_present, "manca il passaggio #{step}"
        expect(ciclo.text).to include(I18n.t("member.tickets.automation.stage.#{step}"))
        expect(ciclo.text).to include(I18n.t("member.guides.agents.steps.#{step}.body"))
      end
    end

    # Le due uscite non le spiegava nessuna guida: adesso ci sono, con le parole della schermata.
    it "spiega anche come si esce dal percorso" do
      get member_guides_agents_path

      uscite = page.at_css("[data-test='member-guide-agents-exits']")
      expect(uscite).to be_present
      Agents::Workflows::PhaseResolver::EXITS.each do |uscita|
        expect(uscite.at_css("[data-test='guide-agents-exit-#{uscita}']")).to be_present, "manca l'uscita #{uscita}"
        expect(uscite.text).to include(I18n.t("member.tickets.automation.stage.#{uscita}"))
        expect(uscite.text).to include(I18n.t("member.guides.agents.exits.#{uscita}.body"))
      end
    end

    it "spiega cosa significa ogni esito di un passaggio" do
      get member_guides_agents_path

      esiti = page.at_css("[data-test='member-guide-agents-outcomes']")
      expect(esiti).to be_present
      %w[approved rejected interrupted failed].each do |esito|
        expect(esiti.at_css("[data-test='guide-agents-outcome-#{esito}']")).to be_present, "manca l'esito #{esito}"
      end
      expect(esiti.text).to include(I18n.t("member.guides.agents.outcomes.rejected.body"))
    end

    it "dice quando arriva una richiesta di approvazione e cosa succede se non si risponde" do
      get member_guides_agents_path

      attesa = page.at_css("[data-test='member-guide-agents-waiting']")
      expect(attesa).to be_present
      expect(attesa.text).to include(I18n.t("member.guides.agents.waiting.no_reply"))
      expect(attesa.text).to include(I18n.t("member.guides.agents.waiting.no_deadline"))
      expect(response.body).to include(member_home_approvals_path)
    end

    it "spiega cosa fa la revoca della certificazione, con la stessa parola del pulsante" do
      get member_guides_agents_path

      revoca = page.at_css("[data-test='member-guide-agents-certification']")
      expect(revoca).to be_present
      expect(revoca.text).to include(I18n.t("member.agents.decertify"))
      expect(revoca.text).to include(I18n.t("member.guides.agents.certification.revoke_body"))
    end

    # The guide stays reachable from the guides index; the approvals header no longer repeats it.
    it "keeps the guide and home shortcuts out of the approvals header" do
      get member_home_approvals_path

      expect(page.at_css("[data-test='approvals-agents-guide']")).to be_nil
      expect(page.at_css("[data-test='approvals-back-home']")).to be_nil
    end

    it "l'indice delle guide ha la sua scheda" do
      get member_guides_path

      expect(response.body).to include("member-guides-card-agents")
    end
  end

  # La terza guida chiesta dalla Definition of Done: le versioni delle competenze (skill bundle).
  describe "la guida sulle versioni delle competenze" do
    before { sign_in(owner) }

    it "dice cos'è la versione fissata, chi la aggiorna e quando si tocca a mano" do
      get member_guides_skill_bundles_path

      expect(response).to have_http_status(:ok)
      expect(page.at_css("[data-test='member-guide-skill-bundles']")).to be_present
      expect(page.at_css("[data-test='member-guide-skill-bundles-what']").text)
        .to include(I18n.t("member.guides.skill_bundles.what_intro"))
      expect(page.at_css("[data-test='member-guide-skill-bundles-check']")).to be_present
      expect(page.at_css("[data-test='member-guide-skill-bundles-rollback']").text)
        .to include(I18n.t("member.guides.skill_bundles.rollback_intro"))
    end

    it "l'indice delle guide ha la sua scheda" do
      get member_guides_path

      expect(response.body).to include("member-guides-card-skill-bundles")
    end
  end

  # Quarto punto della Definition of Done: aprendo una guida il menu laterale non cambia. La sidebar
  # è una sola da CYRA-521; qui si tiene fermo, perché è esattamente la regressione del ticket.
  describe "aprendo una guida il menu laterale resta quello di prima" do
    before { sign_in(owner) }

    def voci_di_menu
      page.css("#member-sidebar [data-test^='member-nav-']").map { |node| node["data-test"] }
    end

    it "le voci sono le stesse della pagina da cui si è partiti" do
      get member_projects_path
      partenza = voci_di_menu
      # Guardia anti-confronto vuoto: due liste vuote sarebbero uguali e il test non direbbe niente.
      expect(partenza).to include("member-nav-projects", "member-nav-guides")

      get member_guides_analytics_path
      expect(voci_di_menu).to eq(partenza)

      get member_guides_agents_path
      expect(voci_di_menu).to eq(partenza)
    end
  end
end
