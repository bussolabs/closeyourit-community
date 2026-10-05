require "rails_helper"

RSpec.describe "Member::Guides", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "membro autenticato con organizzazione" do
    before do
      create(:membership, account: account, organization: org, role: :member)
      sign_in(account)
    end

    it "GET index → 200" do
      get member_guides_path
      expect(response).to have_http_status(:ok)
    end

    # CYRA-435 — le due guide d'insieme: la mappa del prodotto e il percorso di un ticket.
    it "GET guides/overview → 200 con i gruppi del menu, come si aprono e il primo giorno" do
      get member_guides_overview_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-guide-overview"')
      gruppi = Nokogiri::HTML(response.body).css('[data-test="guide-overview-space"]')
      attesi = Navigation::Group.all.reject(&:pinned?).map(&:id)
      expect(gruppi.size).to eq(attesi.size)
      expect(gruppi.map { |node| node["data-space"] }).to match_array(attesi)
      expect(response.body).to include(I18n.t("member.guides.overview.spaces_switch"))
      expect(response.body).to include('data-test="guide-overview-chain"')
      expect(response.body).to include('data-test="guide-overview-first-day"')
      expect(response.body).to include(I18n.t("member.guides.overview.first_day_3"))
    end

    it "ogni area della guida introduttiva ha la sua riga di spiegazione" do
      get member_guides_overview_path

      Navigation::Group.all.reject(&:pinned?).each do |group|
        expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.guides.overview.spaces.#{group.id}")))
      end
    end

    it "GET guides/ticket-lifecycle → 200 con stati, dove si guardano e cosa si scrive" do
      get member_guides_ticket_lifecycle_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-guide-ticket-lifecycle"')
      expect(response.body).to include('data-test="guide-lifecycle-states"')
      expect(response.body).to include('data-test="guide-lifecycle-where"')
      expect(response.body).to include('data-test="guide-lifecycle-work"')
    end

    # CYRA-631 — gli stati sono quelli di CHI LEGGE. Prima ne erano quattro scritti a mano su cinque
    # installati: «Risolto» non compariva da nessuna parte, e uno stato aggiunto da un'organizzazione
    # non sarebbe comparso mai. Non basta contarli: due organizzazioni devono vedere cose diverse, o
    # la prova passerebbe anche con l'elenco riscritto a mano dentro la vista.
    it "mostra gli stati attivi di CHI legge, non un elenco scritto a mano" do
      mio = create(:ticket_status, organization: org, label: "Nostro stato", code: "nostro", position: 9)
      altra_org = create(:organization)
      suo = create(:ticket_status, organization: altra_org, label: "Stato dell'altra", code: "altrui", position: 9)
      spento = create(:ticket_status, organization: org, label: "Stato spento", code: "spento",
                                      position: 10, active: false)

      get member_guides_ticket_lifecycle_path

      expect(response.body).to include(ERB::Util.html_escape(mio.display_label))
      expect(response.body).not_to include(ERB::Util.html_escape(suo.display_label))
      expect(response.body).not_to include(ERB::Util.html_escape(spento.display_label))
    end

    # La spiegazione è quella CANONICA per stato, la stessa che la scheda del ticket mostra sotto lo
    # stato. Se la guida ne tenesse una copia, cambiare la canonica lascerebbe le due schermate a
    # dire due cose diverse sulla stessa parola — che è il difetto che questo ticket chiude.
    it "spiega ogni stato con la frase canonica, non con una copia sua" do
      # I cinque stati di partenza, coi codici canonici: la prova è sulle FRASI, non su chi li installa.
      %w[open in_progress in_review resolved closed].each_with_index do |code, i|
        create(:ticket_status, organization: org, code: code, label: code.humanize, position: i)
      end

      get member_guides_ticket_lifecycle_path

      testo = Nokogiri::HTML(response.body).at_css('[data-test="guide-lifecycle-states"]').text
      %w[open in_progress in_review resolved closed].each do |code|
        expect(testo).to include(I18n.t("ticketing.status_hints.#{code}")), "manca la frase di #{code}"
      end
    end

    # Uno stato aggiunto da un'organizzazione non ha una frase canonica: compare col suo nome, come
    # sulla scheda del ticket, e non con un segnaposto di traduzione.
    it "uno stato aggiunto compare col suo nome, senza segnaposto" do
      mio = create(:ticket_status, organization: org, label: "Nostro stato", code: "nostro", position: 9)

      get member_guides_ticket_lifecycle_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="guide-lifecycle-state-nostro"]')
      expect(riga).to be_present
      expect(riga.text).to include(mio.display_label)
      expect(riga.text).not_to match(/translation missing/i)
    end

    # L'ordine è quello della bacheca: se la guida ordinasse per conto suo, chi confronta le due
    # schermate leggerebbe due percorsi diversi per lo stesso ticket.
    it "li mostra nell'ordine della bacheca" do
      create(:ticket_status, organization: org, label: "Terzo", code: "terzo", position: 3)
      create(:ticket_status, organization: org, label: "Primo", code: "primo", position: 1)
      create(:ticket_status, organization: org, label: "Secondo", code: "secondo", position: 2)

      get member_guides_ticket_lifecycle_path

      resi = Nokogiri::HTML(response.body).css('[data-test^="guide-lifecycle-state-"]')
                                          .map { |n| n["data-test"].sub("guide-lifecycle-state-", "") }
      attesi = Types::TicketStatus.active.ordered.where(organization: org).map(&:code)

      expect(resi).to eq(attesi)
      expect(resi).not_to be_empty
    end

    # CYRA-441 — i contenitori dentro cui vive tutto il resto (organizzazione, gruppi, progetti,
    # ambienti, piattaforme) erano più di dieci concetti che si incrociano fra loro, e nessuna pagina
    # li introduceva. L'insieme di progetti si chiama «Gruppo», mai più «macro-progetto» (CYRA-362).
    it "GET guides/structure → 200 con i contenitori in ordine, come si incrociano e dove si dichiarano" do
      get member_guides_structure_path

      expect(response).to have_http_status(:ok)
      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='member-guide-structure']")).to be_present
      expect(pagina.at_css("[data-test='member-guide-structure-chain']").text)
        .to include(I18n.t("member.guides.structure.chain_intro"))
      expect(pagina.at_css("[data-test='member-guide-structure-cross']").text)
        .to include(I18n.t("member.guides.structure.cross_uptime"))
      expect(pagina.at_css("[data-test='member-guide-structure-where']")).to be_present
      expect(response.body).to include(member_platforms_path)
      expect(response.body).to include(member_environments_path)
    end

    # Una guida nuova porta una trentina di voci di testo: basta una chiave scritta in una lingua
    # sola e chi ha scelto l'altra legge il segnaposto di i18n in mezzo alla spiegazione.
    %i[it en].each do |lingua|
      it "guides/structure: in #{lingua} nessuna voce di testo resta senza traduzione" do
        I18n.with_locale(lingua) do
          get member_guides_structure_path
          expect(response.body).not_to include("translation missing")
        end
      end
    end

    it "guides/structure: i cinque contenitori hanno ciascuno il suo nome e la sua riga" do
      get member_guides_structure_path

      catena = Nokogiri::HTML(response.body).at_css("[data-test='member-guide-structure-chain']")
      %w[organization group project environment platform].each do |contenitore|
        expect(catena.text).to include(I18n.t("member.guides.structure.chain.#{contenitore}.title"))
        expect(catena.text).to include(I18n.t("member.guides.structure.chain.#{contenitore}.body"))
      end
    end

    it "index: la guida dei contenitori ha la sua card" do
      get member_guides_path
      expect(response.body).to include("member-guides-card-structure")
    end

    it "GET guides/approvals → 200" do
      get member_guides_approvals_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-guide-approvals"')
    end

    # CYRA-504 — chi non sa che il rilascio in produzione aspetta il suo via libera lo aspetta e basta:
    # la guida lo dice, insieme al fatto che non si respinge e non si approva in blocco.
    it "GET guides/approvals spiega il via libera alla produzione" do
      get member_guides_approvals_path

      expect(response.body).to include('data-test="member-guide-approvals-production"')
      expect(response.body).to include(I18n.t("member.guides.approvals.production_title"))
    end

    it "GET guides/errors → 200" do
      get member_guides_errors_path
      expect(response).to have_http_status(:ok)
    end

    # CYRA-454 — i Dataset erano l'unica funzione dell'area Automazione senza guida: chi apriva la
    # pagina vuota non aveva nessun posto dove capire quando serve.
    it "GET guides/datasets → 200 con l'esempio, i passi e cosa NON è" do
      get member_guides_datasets_path

      expect(response).to have_http_status(:ok)
      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='member-guide-datasets']")).to be_present
      expect(pagina.at_css("[data-test='member-guide-datasets-what']").text)
        .to include(I18n.t("member.guides.datasets.what_intro"))
      expect(pagina.at_css("[data-test='member-guide-datasets-how']")).to be_present
      expect(pagina.at_css("[data-test='member-guide-datasets-not']").text)
        .to include(I18n.t("member.guides.datasets.not_intro"))
      expect(response.body).to include(member_datasets_path)
    end

    it "index: la guida dei Dataset ha la sua card" do
      get member_guides_path
      expect(response.body).to include("member-guides-card-datasets")
    end

    # CYRA-545 — la pagina Integrazioni si legge in fretta, ma cos'è una chiave, chi ne paga il
    # consumo, perché non si rilegge più e cosa si spegne togliendola non stanno in una schermata.
    it "GET guides/integrations → 200 con i servizi, i passi e cosa si spegne" do
      get member_guides_integrations_path

      expect(response).to have_http_status(:ok)
      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='member-guide-integrations']")).to be_present
      expect(pagina.at_css("[data-test='member-guide-integrations-key']").text)
        .to include(I18n.t("member.guides.integrations.key_intro"))
      expect(pagina.at_css("[data-test='member-guide-integrations-off']").text)
        .to include(I18n.t("member.guides.integrations.off_intro"))
      # I servizi non sono un elenco scritto a mano: escono dal registro, come in pagina.
      Integrations::Providers.all.each do |provider|
        expect(pagina.at_css("[data-test='member-guide-integrations-services']").text).to include(provider.label)
      end
      expect(response.body).to include(member_integrations_path)
    end

    it "index: la guida delle Integrazioni ha la sua card" do
      get member_guides_path
      expect(response.body).to include("member-guides-card-integrations")
    end

    # CYRA-879 — moving a project or group to another organization: who can, blockers, what detaches.
    it "GET guides/project-moves renders the blockers and the notes, and the index links it" do
      get member_guides_project_moves_path

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-test='guide-project-moves-blockers']").text)
        .to include(I18n.t("member.guides.project_moves.blocker_agent"))
      expect(page.at_css("[data-test='guide-project-moves-notes']").text)
        .to include(I18n.t("member.guides.project_moves.note_github"))

      get member_guides_path
      expect(response.body).to include("member-guides-card-project-moves")
    end

    it "GET guides/uptime → 200" do
      get member_guides_uptime_path
      expect(response).to have_http_status(:ok)
    end

    # CYRA-376 — nessuna delle guide nominava le registrazioni: la funzione più vendibile del
    # prodotto non aveva una riga che dicesse cos'è, come si accende e cosa NON registra.
    it "GET guides/replays → 200 con cos'è, come si accende e cosa non finisce nella registrazione" do
      get member_guides_replays_path

      expect(response).to have_http_status(:ok)
      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='member-guide-replays']")).to be_present
      expect(pagina.at_css("[data-test='member-guide-replays-setup']").text)
        .to include(I18n.t("member.guides.replays.setup_title"))
      expect(pagina.at_css("[data-test='member-guide-replays-privacy']").text)
        .to include(I18n.t("member.guides.replays.privacy_title"))
      expect(response.body).to include(member_monitoring_replays_path)
    end

    it "index: la guida delle registrazioni ha la sua card" do
      get member_guides_path
      expect(response.body).to include("member-guides-card-replays")
    end

    # CYRA-476: la guida sul controllo dei siti ha un passo finale dedicato a farsi avvisare quando cade.
    it "guides/uptime: contiene il passo su come farsi avvisare (CYRA-476)" do
      get member_guides_uptime_path
      section = Nokogiri::HTML(response.body).at_css("[data-test='member-guide-uptime-alerts']")
      expect(section).to be_present
      expect(section.text).to include(I18n.t("member.guides.uptime.alert_title"))
      expect(response.body).to include(member_alerting_rules_path)
    end

    # CYRA-380: la guida errori deve spiegare come inviare l'informazione su chi è stato colpito, così
    # la colonna «Utenti» smette di restare vuota.
    it "guides/errors: contiene la sezione su come tracciare le persone colpite (CYRA-380)" do
      get member_guides_errors_path
      # .text decodifica le entità HTML (gli apostrofi diventano &#39; nel body) → confronto robusto.
      section = Nokogiri::HTML(response.body).at_css("[data-test='member-guide-errors-affected']")
      expect(section).to be_present
      expect(section.text).to include(I18n.t("member.guides.errors.affected_title"))
      expect(section.text).to include(I18n.t("member.guides.errors.affected_intro"))
    end

    # CYRA-397 — la guida valeva per un linguaggio solo, mentre l'ingest riceve già da JS e Flutter:
    # chi non usa Ruby non aveva nessuna strada d'ingresso. E indicava un percorso di menu inesistente.
    describe "la guida errori copre tutti i kit pubblicati" do
      def page_of(sdk = nil)
        get member_guides_errors_path(sdk:)
        Nokogiri::HTML(response.body)
      end

      it "si sceglie il kit, e ognuno porta le sue istruzioni" do
        expect(page_of.at_css("[data-test='guide-errors-sdk-picker']")).to be_present

        expect(page_of("ruby").text).to include("closeyourit-ruby")
        expect(page_of("js").text).to include("@bussolabs/closeyourit-js")
        expect(page_of("dart").text).to include("flutter pub add")
      end

      it "senza scelta parte dal primo kit, e un kit inventato non svuota la pagina" do
        expect(page_of.at_css("[data-test='guide-errors-sdk-ruby'][aria-current='page']")).to be_present
        expect(page_of("perl").at_css("[data-test='guide-errors-sdk-ruby'][aria-current='page']")).to be_present
      end

      # Il passo 3 mandava a «Monitor › Errors», che nel menu non esiste. Ora le parole sono le stesse
      # della sidebar: non possono più divergere.
      it "il percorso di menu è quello vero" do
        testo = page_of.at_css("[data-test='guide-errors-step3']").text

        expect(testo).to include(I18n.t("member.nav.section_observability"))
        expect(testo).to include(I18n.t("member.nav.errors"))
        expect(response.body).not_to include("Monitor › Errors")
      end

      it "spiega perché gli errori del browser sono illeggibili e cosa si può fare" do
        sezione = page_of.at_css("[data-test='member-guide-errors-sourcemaps']")

        expect(sezione).to be_present
        expect(sezione.text).to include(I18n.t("member.guides.errors.sourcemaps_limit"))
      end

      it "spiega come si accendono le sessioni registrate" do
        sezione = page_of.at_css("[data-test='member-guide-errors-replays']")

        expect(sezione).to be_present
        expect(sezione.text).to include(I18n.t("member.guides.errors.replays_step2"))
      end

      # Il rischio dichiarato nel ticket: documentare un kit non ancora pubblicato crea aspettative.
      #
      # Si guarda il SELETTORE dei kit, non tutta la pagina. Cercare «python» in tutto il testo
      # significa cercarlo anche nei dati: basta che un altro spec dello stesso shard lasci in giro
      # un progetto, un ticket o un errore che quella parola ce l'ha, e questa prova diventa rossa
      # parlando di una guida che non è cambiata. È già successo, ed è costato un giro di CI.
      it "non nomina kit che non esistono ancora" do
        selettore = page_of.at_css("[data-test='guide-errors-sdk-picker']")

        expect(selettore).to be_present
        expect(selettore.text).not_to match(/python/i)
      end
    end

    # La guida dei log spiegava a cosa servono e poi lasciava lì chi voleva mandarli: il passo 2
    # diceva «segui le istruzioni», senza istruzioni.
    it "guides/logs: dice come collegare l'applicazione, non solo che si può" do
      get member_guides_logs_path

      expect(response.body).to include("closeyourit-ruby")
      expect(response.body).to include("CLOSEYOURIT_PROJECT_ID")
      expect(Nokogiri::HTML(response.body).at_css("[data-test='guide-logs-endpoint']").text)
        .to include("/api/v1/projects/:id/logs")
    end

    # Un terzo dei dati sono «problemi di performance», e proprio i tipi meno intuitivi non erano
    # spiegati da nessuna parte. I nomi vengono dalle stesse chiavi delle schede: non possono divergere.
    it "guides/performance: descrive tutti e sette i rallentamenti trovati in automatico" do
      get member_guides_performance_path

      sezione = Nokogiri::HTML(response.body).at_css("[data-test='member-guide-performance-issues']")
      expect(sezione).to be_present
      Metrics::Group::PERFORMANCE_SUBTYPES.each do |subtype|
        expect(sezione.at_css("[data-test='performance-issue-#{subtype}']")).to be_present, "manca #{subtype}"
        expect(sezione.text).to include(I18n.t("member.metrics.subtype_hint.#{subtype}"))
      end
    end

    it "GET guides/performance → 200" do
      get member_guides_performance_path
      expect(response).to have_http_status(:ok)
    end

    it "GET guides/logs → 200" do
      get member_guides_logs_path
      expect(response).to have_http_status(:ok)
    end

    it "GET guides/servers → 200" do
      get member_guides_servers_path
      expect(response).to have_http_status(:ok)
    end

    it "GET guides/analytics → 200" do
      get member_guides_analytics_path
      expect(response).to have_http_status(:ok)
    end

    it "GET guides/secrets → 200" do
      get member_guides_secrets_path
      expect(response).to have_http_status(:ok)
    end

    # CYRA-160 — il riepilogo periodico dei dati: cosa contiene, quando arriva e perché non è la
    # stessa cosa degli avvisi. Dalla guida si torna alla pagina che lo accende.
    it "GET guides/reports → 200, e rimanda alle preferenze da cui si accende" do
      get member_guides_reports_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(member_notification_preferences_path)
    end

    # CYRA-416: guida e interfaccia devono usare la stessa parola per la stessa operazione —
    # la label «Delega» per dare l'accesso, «Revoca» per toglierlo. Confronto con le stesse
    # chiavi i18n dell'interfaccia, così resta valido in ogni lingua.
    it "guides/secrets: usa le stesse parole dell'interfaccia per delegare e revocare (CYRA-416)" do
      get member_guides_secrets_path
      text = Nokogiri::HTML(response.body).text.downcase
      expect(text).to include(I18n.t("member.shared_secrets.delegate").downcase)
      expect(text).to include(I18n.t("member.shared_secrets.unlink").downcase)
    end

    # CYRA-446 — «Vault» e «Secret dell'organizzazione» sono due guide vicine che con parole quasi
    # identiche descrivono un contenitore e uno dei suoi tre spazi. Chi deve mettere via una password
    # non sapeva dove va, e un segreto nel posto sbagliato è un segreto letto da chi non doveva. Le
    # due guide aprono ora sulla stessa differenza — resa dallo stesso partial, così non possono
    # divergere — e ognuna rimanda all'altra.
    describe "la differenza fra Vault e Secret dell'organizzazione (CYRA-446)" do
      it "la guida del Vault apre dichiarando la differenza e rimanda all'altra guida" do
        get member_guides_vault_path

        pagina = Nokogiri::HTML(response.body)
        riquadro = pagina.at_css("[data-test='guides-secrets-split']")
        expect(riquadro).to be_present
        expect(riquadro.text).to include(I18n.t("member.guides.vault.title"))
        expect(riquadro.text).to include(I18n.t("member.guides.secrets.title"))
        expect(riquadro.at_css("[data-test='guides-secrets-split-link']")["href"]).to eq(member_guides_secrets_path)
      end

      it "la guida dei secret dell'organizzazione apre con la stessa differenza e rimanda al Vault" do
        get member_guides_secrets_path

        pagina = Nokogiri::HTML(response.body)
        riquadro = pagina.at_css("[data-test='guides-secrets-split']")
        expect(riquadro).to be_present
        expect(riquadro.text).to include(I18n.t("member.guides.vault.title"))
        expect(riquadro.text).to include(I18n.t("member.guides.secrets.title"))
        expect(riquadro.at_css("[data-test='guides-secrets-split-link']")["href"]).to eq(member_guides_vault_path)
      end

      # Scenario 1: la differenza si legge PRIMA del corpo della guida, non in fondo dopo aver letto
      # una pagina che non era quella giusta.
      it "sulla guida del Vault il riquadro sta prima del primo capitolo" do
        get member_guides_vault_path

        expect(response.body.index("data-test=\"guides-secrets-split\""))
          .to be < response.body.index(ERB::Util.html_escape(I18n.t("member.guides.vault.what_title")))
      end

      it "sulla guida dei secret dell'organizzazione il riquadro sta prima del primo capitolo" do
        get member_guides_secrets_path

        expect(response.body.index("data-test=\"guides-secrets-split\""))
          .to be < response.body.index(ERB::Util.html_escape(I18n.t("member.guides.secrets.what_title")))
      end

      # DoD 3: non basta ripetere i due nomi — la riga dice dove finisce il valore in ciascun caso.
      # Cosa dica esattamente, nelle due lingue, lo presidia spec/i18n/secrets_vocabulary_spec.rb.
      it "dice la conseguenza pratica: dove va il valore e chi lo vede" do
        get member_guides_vault_path

        regola = Nokogiri::HTML(response.body).at_css("[data-test='guides-secrets-split-rule']")
        expect(regola).to be_present
        expect(regola.text).to eq(I18n.t("member.guides.secrets_split.rule"))
      end
    end

    it "GET guides/knowledge → 200" do
      get member_guides_knowledge_path
      expect(response).to have_http_status(:ok)
    end

    # CYRA-768 — la data di rilettura è una regola che si scopre solo leggendo: la guida deve dirla.
    it "la guida della conoscenza spiega quando una pagina va riletta" do
      get member_guides_knowledge_path

      expect(response.body).to include('data-test="member-guide-knowledge-review-after"')
      expect(response.body).to include(I18n.t("member.guides.knowledge.reread_title"))
    end

    it "GET guides/tickets → 200" do
      get member_guides_tickets_path
      expect(response).to have_http_status(:ok)
    end

    it "GET guides/guidance → 200" do
      get member_guides_guidance_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-guide-guidance"')
    end

    it "index: mostra le card delle nuove guide" do
      get member_guides_path
      %w[logs servers analytics secrets knowledge tickets guidance].each do |slug|
        expect(response.body).to include("member-guides-card-#{slug}")
      end
    end

    it "guides/logs: la CTA porta alla pagina dei log" do
      get member_guides_logs_path
      expect(response.body).to include(member_monitoring_log_entries_path)
    end
  end

  # Le guide in italiano mandavano a voci che nel prodotto hanno un altro nome: «Infrastructure ›
  # Uptime», «sotto Knowledge», la scheda «Ingest tokens» (è «Token di ingest»), «Avvisi» per le
  # regole. Chi cercava quelle parole nel menu non le trovava.
  describe "in italiano le guide chiamano le pagine col loro nome vero" do
    let(:account) { create(:account, locale: "it") }

    before do
      create(:membership, account: account, organization: org, role: :member)
      sign_in(account)
    end

    def testo_di(path)
      get path
      Nokogiri::HTML(response.body).at_css("main").text
    end

    it "uptime: il percorso di menu e le regole di avviso usano le etichette della barra laterale" do
      testo = testo_di(member_guides_uptime_path)

      I18n.with_locale(:it) do
        expect(testo).to include("#{I18n.t('member.nav.group_infrastructure')} › #{I18n.t('member.nav.uptime')}")
        expect(testo).to include(I18n.t("member.nav.alert_rules"))
      end
      expect(testo).not_to include("Infrastructure ›")
      expect(testo).not_to include("Health check")
    end

    { "errori" => :member_guides_errors_path, "performance" => :member_guides_performance_path }.each do |nome, path|
      it "#{nome}: la scheda del progetto si chiama come sulla pagina del progetto" do
        testo = testo_di(public_send(path))

        expect(testo).not_to include("Ingest tokens")
        # CYRA-883 — the tokens moved into Settings: the guide names the tab and the section.
        expect(testo).to include(I18n.t("member.projects.show.tab_settings", locale: :it))
        expect(testo).to include(I18n.t("member.tokens.section_title", locale: :it))
      end
    end

    # Da quando i ruoli si compongono, smistare e trasformare in ticket sono due permessi: «admin e
    # owner» mandava a cercare un ruolo che non decide più niente.
    it "errori: chi può smistare lo dicono i permessi veri, non «admin e owner»" do
      testo = testo_di(member_guides_errors_path)

      expect(testo).not_to include("admin e owner")
      I18n.with_locale(:it) do
        permessi = I18n.t("authorization.permissions")
        expect(testo).to include(permessi[:"errors.triage"], permessi[:"errors.promote"])
      end
    end

    it "errori: il pulsante in fondo porta agli Errori, non a «Errors»" do
      expect(testo_di(member_guides_errors_path)).not_to include("Vai a Errors")
    end

    it "revisione: il menu si chiama come nella barra laterale" do
      testo = testo_di(member_guides_knowledge_review_path)

      expect(testo).to include("sotto #{I18n.t('member.nav.group_knowledge', locale: :it)}")
    end

    it "ruoli: il menu si chiama come nella barra laterale" do
      testo = testo_di(member_guides_permissions_path)

      I18n.with_locale(:it) { expect(testo).to include("#{I18n.t('member.nav.roles')} da #{I18n.t('member.nav.group_settings')}") }
    end

    # Accanto all'etichetta «Bug» la riga ripeteva «Bug: …»: il nome si leggeva due volte di fila.
    it "tipi di ticket: la spiegazione accanto all'etichetta non ripete il nome del tipo" do
      get member_guides_tickets_path

      righe = Nokogiri::HTML(response.body).css("[data-test='member-guide-tickets'] ul").first.css("li")
      righe.each { |riga| expect(riga.css("span").last.text).not_to start_with(riga.css("span").first.text.strip) }
    end

    it "il percorso di un ticket chiama i tipi come li mostra il ticket" do
      testo = testo_di(member_guides_ticket_lifecycle_path)

      %w[bug story task epic].each { |kind| expect(testo).to include(I18n.t("member.tickets.kind.#{kind}", locale: :it)) }
    end
  end

  describe "utente non autenticato" do
    it "GET index reindirizza al login" do
      get member_guides_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "account autenticato senza organizzazione" do
    before { sign_in(account) }

    it "GET index reindirizza alla home" do
      get member_guides_path
      expect(response).to redirect_to(root_path)
    end
  end

  # CYRA-336 — le guide sono l'unica pagina che risponde a «cosa sa fare questo strumento», e ne
  # spiegavano un terzo: chi arrivava non poteva sapere cosa fanno le altre pagine.
  describe "il catalogo copre tutto il prodotto" do
    it "elenca le voci del menu con la loro riga di spiegazione" do
      create(:membership, account:, organization: org, role: :member)
      sign_in(account)
      get member_guides_path

      pagina = Nokogiri::HTML(response.body)
      catalogo = pagina.at_css("[data-test='member-guides-catalog']")
      expect(catalogo).to be_present
      expect(catalogo.css("[data-test='guides-catalog-item']").size).to be >= 10
      expect(catalogo.text).to include(I18n.t("member.guides.catalog.tickets"))
    end

    # Fuori dal catalogo: le voci sempre a vista in cima (non serve un catalogo per trovarle)
    # e le panoramiche dei gruppi, che sono pagine d'ingresso e non funzioni da spiegare.
    # CYRA-630 — «workflows» non è più fra queste: la voce è sparita dal menu insieme alla sua
    # guida, e quello che diceva lo dice adesso il secondo numero sulla pagina delle decisioni.
    VOCI_FISSE = %w[home approvals conversations home-todos guides].freeze

    it "ogni voce di menu di ogni gruppo ha la sua riga: nessuna pagina resta senza spiegazione" do
      chiavi = File.read(Rails.root.join("app/helpers/member/navigation_helper.rb"))
                   .scan(/test: "member-nav-([a-z0-9_-]+)"/).flatten.uniq
                   .reject { |chiave| chiave.start_with?("section-") || chiave.end_with?("-overview") }
                   .reject { |chiave| chiave.in?(VOCI_FISSE) }

      senza_riga = chiavi.reject { |chiave| I18n.exists?("member.guides.catalog.#{chiave.tr('-', '_')}", :it) }

      expect(senza_riga).to be_empty
    end

    it "la stessa copertura vale in inglese" do
      chiavi = File.read(Rails.root.join("app/helpers/member/navigation_helper.rb"))
                   .scan(/test: "member-nav-([a-z0-9_-]+)"/).flatten.uniq
                   .reject { |chiave| chiave.start_with?("section-") || chiave.end_with?("-overview") }
                   .reject { |chiave| chiave.in?(VOCI_FISSE) }

      senza_riga = chiavi.reject { |chiave| I18n.exists?("member.guides.catalog.#{chiave.tr('-', '_')}", :en) }

      expect(senza_riga).to be_empty
    end
  end
end
