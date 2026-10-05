# frozen_string_literal: true

require "rails_helper"

# CYRA-648 — la guida diceva che le registrazioni si accendono «senza toccare il codice»: falso. Il
# solo interruttore sul progetto apre il canale lato server, ma il sito non manda niente finché non
# carica la libreria di registrazione e non chiede il replay nel codice di avvio. Chi seguiva la
# guida alla lettera accendeva l'interruttore e non vedeva mai una sessione, senza nessun errore da
# nessuna parte: il degrado è silenzioso per costruzione (il kit è zero-dipendenze e senza
# `window.rrweb` il recorder è un no-op).
RSpec.describe "Member — guida al replay: il codice da mettere nel sito (CYRA-648)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  # Progetto su cui il replay è possibile: piattaforma web dichiarata (capability), che è la stessa
  # condizione con cui l'interruttore compare nelle impostazioni.
  let(:project) { create(:project, organization: org, name: "Sito vetrina").tap { |p| p.platforms << web } }

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

  # Scenario 1 del ticket: chi segue tutti i passaggi deve vedere davvero arrivare una sessione.
  describe "la guida mostra il codice completo da incollare nel sito" do
    it "stampa lo snippet compilato per il progetto scelto, con il pulsante per copiarlo" do
      create(:project_token, project:, public_key: "a" * 32)
      sign_in(owner)

      get member_guides_replays_path

      expect(response).to have_http_status(:ok)
      snippet = page.at_css("[data-test='guide-replays-snippet']")
      expect(snippet).to be_present
      expect(snippet.text).to include(project.id)
      expect(snippet.text).to include("a" * 32)
      expect(page.at_css("[data-test='guide-replays-copy']")).to be_present
    end

    # Le due righe che mancavano, e senza le quali l'interruttore acceso non produce niente.
    it "il codice chiede il replay e carica la libreria che lo registra" do
      sign_in(owner)

      get member_guides_replays_path

      snippet = page.at_css("[data-test='guide-replays-snippet']").text
      expect(snippet).to include("replay: true")
      expect(snippet).to include("rrweb")
      expect(snippet).to include("closeyourit.min.js")
    end

    # L'indirizzo `dist/rrweb.umd.min.cjs` è lo STESSO file, ma jsDelivr lo serve con
    # `content-type: application/node` e `x-content-type-options: nosniff`: il browser si rifiuta di
    # eseguirlo, quindi `window.rrweb` non esiste e la guida tornerebbe a promettere registrazioni
    # che non arrivano. L'entrypoint che il pacchetto dichiara per jsDelivr è sotto `umd/`.
    it "la libreria è chiesta all'indirizzo che il browser accetta di eseguire" do
      sign_in(owner)

      get member_guides_replays_path

      snippet = page.at_css("[data-test='guide-replays-snippet']").text
      expect(snippet).to include("rrweb@2/umd/rrweb.min.js")
      expect(snippet).not_to include(".cjs")
    end

    # Chi gestisce i codici ma non ne ha ancora nessuno vede il segnaposto: dire «la chiave nel
    # codice è quella del progetto scelto» sarebbe falso, e il codice verrebbe incollato così.
    it "senza nessun codice attivo dice che ne manca uno, invece di spacciare il segnaposto per la chiave" do
      project
      sign_in(owner)

      get member_guides_replays_path

      expect(page.at_css("[data-test='guide-replays-snippet']").text)
        .to include(I18n.t("member.monitoring.analytics.onboarding.key_placeholder"))
      expect(page.at_css("[data-test='guide-replays-token-missing']")).to be_present
      expect(response.body).not_to include(I18n.t("member.guides.replays.token_where"))
    end

    it "si sceglie il progetto, e la scelta cambia il codice mostrato" do
      altro = create(:project, organization: org, name: "Blog").tap { |p| p.platforms << web }
      create(:project_token, project: altro, public_key: "b" * 32)
      project
      sign_in(owner)

      get member_guides_replays_path(project_id: altro.id)

      expect(page.at_css("[data-test='guide-replays-project-picker']")).to be_present
      expect(page.at_css("[data-test='guide-replays-snippet']").text).to include(altro.id)
      expect(page.at_css("[data-test='guide-replays-snippet']").text).to include("b" * 32)
    end

    # Anti-BOLA: un progetto di un'altra organizzazione (o un id inventato) non deve né comparire né
    # far esplodere una pagina di sola lettura.
    it "un progetto non visibile non svuota la pagina: torna al primo che si può leggere" do
      estraneo = create(:project)
      project
      sign_in(owner)

      get member_guides_replays_path(project_id: estraneo.id)

      expect(response).to have_http_status(:ok)
      expect(page.at_css("[data-test='guide-replays-snippet']").text).to include(project.id)
    end

    # La chiave pubblica è una credenziale di ingest e la sua pagina sta dietro tokens.manage: la
    # guida la legge chiunque, quindi vale lo stesso confine della guida delle statistiche.
    it "a chi non gestisce i codici mostra il segnaposto, mai la chiave vera" do
      create(:project_token, project:, public_key: "c" * 32)
      create(:project_membership, account: member, project:)
      sign_in(member)

      get member_guides_replays_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("c" * 32)
      expect(page.at_css("[data-test='guide-replays-snippet']").text)
        .to include(I18n.t("member.monitoring.analytics.onboarding.key_placeholder"))
      expect(page.at_css("[data-test='guide-replays-token-locked']")).to be_present
    end

    it "senza progetti con una piattaforma web la guida resta leggibile, con l'esempio" do
      sign_in(owner)

      get member_guides_replays_path

      expect(response).to have_http_status(:ok)
      expect(page.at_css("[data-test='guide-replays-project-picker']")).to be_nil
      expect(page.at_css("[data-test='guide-replays-snippet']").text).to include("CloseYourIt.init")
      expect(page.at_css("[data-test='guide-replays-no-project']")).to be_present
    end
  end

  describe "il passo dell'interruttore porta dove si può davvero premere" do
    it "chi può cambiare le impostazioni del progetto scelto ha il bottone che ci porta" do
      project
      sign_in(owner)

      get member_guides_replays_path

      bottone = page.at_css("[data-test='member-guide-replays-project']")
      expect(bottone).to be_present
      expect(bottone["href"]).to eq(member_project_settings_path(project))
    end

    it "chi non può cambiarle non riceve un invito verso una porta chiusa" do
      create(:project_membership, account: member, project:)
      sign_in(member)

      get member_guides_replays_path

      expect(page.at_css("[data-test='member-guide-replays-project']")).to be_nil
      expect(page.at_css("[data-test='member-guide-replays-settings-locked']")).to be_present
    end
  end

  # La guida degli errori è la seconda porta d'ingresso alle registrazioni, e diceva la stessa cosa
  # incompleta: chi passava di lì restava con l'idea che bastasse l'interruttore.
  describe "anche la scorciatoia dalla guida degli errori nomina il codice" do
    it "elenca il passo del codice e porta alla guida che lo mostra" do
      sign_in(owner)

      get member_guides_errors_path

      sezione = page.at_css("[data-test='member-guide-errors-replays']")
      expect(sezione.text).to include(I18n.t("member.guides.errors.replays_step3"))
      link = page.at_css("[data-test='member-guide-errors-replays-guide']")
      expect(link).to be_present
      expect(link["href"]).to eq(member_guides_replays_path)
    end
  end

  # La frase che ha prodotto le integrazioni rotte in silenzio: prometteva che bastasse
  # l'interruttore. Vietata in entrambe le lingue, non solo in quella con cui si sta guardando.
  describe "la guida non promette più che basti l'interruttore" do
    it "in nessuna delle due lingue dice che si accende senza toccare il codice" do
      %i[it en].each do |locale|
        testo = I18n.t("member.guides.replays.setup_intro", locale:)

        expect(testo).not_to match(/senza toccare il codice/i)
        expect(testo).not_to match(/without touching the code/i)
      end
    end
  end
end
