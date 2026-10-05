# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Knowledge::Pages", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  # I due attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune faceva pagare a tutti e due gli account.
  let(:owner) { account_with_membership(:owner) }
  # Scoping: il member vede le pagine dei progetti a cui è assegnato.
  let(:member) { account_with_membership(:member, on_project: true) }

  def account_with_membership(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: role)
      create(:project_membership, account: account, project: project) if on_project
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET /member/knowledge/pages" do
    it "risponde con 200 e mostra le pagine dei progetti visibili" do
      page = create(:knowledge_page, organization: org, project: project, title: "Setup ambienti")
      sign_in(member)

      get member_knowledge_pages_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Setup ambienti")
      expect(response.body).to include("data-test=\"knowledge-counts\"")
      expect(page.project_id).to eq(project.id)
    end

    it "un titolo lungo va a capo su due righe invece di essere mozzato, e nessuna scritta dice «KB»" do
      long_title = "LegalBloom — la rinuncia a un importo già fatturato passa da una nota di credito dell'avvocato"
      create(:knowledge_page, organization: org, project: project, title: long_title)
      sign_in(member)

      get member_knowledge_pages_path
      link = Nokogiri::HTML(response.body).at_css("[data-test='knowledge-row'] a")
      expect(link["class"]).to include("line-clamp-2")
      expect(link["class"]).not_to include("truncate")
      expect(response.body).not_to match(/\bKB\b/)
    end

    it "rende i risultati in un turbo-frame col pulsante Cerca e il selettore di modalità (CYRA-417)" do
      sign_in(member)
      get member_knowledge_pages_path

      expect(response.body).to include('id="knowledge-results"')
      expect(response.body).to include('data-test="knowledge-search-submit"')
      # La modalità è una scelta esplicita (per significato / parole esatte), non più fissa e implicita.
      expect(response.body).to include('name="semantic"')
      expect(response.body).to include(I18n.t("shared.tables.search_mode.semantic"))
      expect(response.body).to include(I18n.t("shared.tables.search_mode.exact"))
    end

    it "esclude le pagine dei progetti non visibili (scoping)" do
      hidden_project = create(:project, organization: org)
      create(:knowledge_page, organization: org, project: hidden_project, title: "Pagina segreta")
      sign_in(member)

      get member_knowledge_pages_path
      expect(response.body).not_to include("Pagina segreta")
    end

    it "non mostra le proposte in revisione né le scartate (CYRA-298)" do
      pubblicata = create(:knowledge_page, organization: org, project: project, title: "Setup ambienti")
      proposta = create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      scartata = create(:knowledge_page, :rejected, organization: org, project: project, title: "Proposta scartata")
      sign_in(member)

      get member_knowledge_pages_path

      expect(response.body).to include(pubblicata.title)
      expect(response.body).not_to include(proposta.title)
      expect(response.body).not_to include(scartata.title)
    end

    it "una proposta in revisione non è raggiungibile dalla show pubblica" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project)
      sign_in(member)

      get member_knowledge_page_path(proposta)

      expect(response).to have_http_status(:not_found)
    end

    it "filtra per kind (param array)" do
      create(:knowledge_page, organization: org, project: project, title: "Nota semplice")
      create(:knowledge_page, :decision, organization: org, project: project, title: "Decisione DB")
      sign_in(member)

      get member_knowledge_pages_path, params: { kind: [ "decision" ] }
      expect(response.body).to include("Decisione DB")
      expect(response.body).not_to include("Nota semplice")
    end

    it "modalità «parole esatte» (semantic=0): ricerca ILIKE, nessun servizio embedding" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy")
      create(:knowledge_page, organization: org, project: project, title: "Onboarding")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "deploy", semantic: "0" }
      expect(response.body).to include("Guida deploy")
      expect(response.body).not_to include("Onboarding")
    end

    it "il link di riga esce dal turbo-frame (data-turbo-frame=_top): la show è full-page, non dentro knowledge-results" do
      page = create(:knowledge_page, organization: org, project: project, title: "Setup ambienti")
      sign_in(member)
      get member_knowledge_pages_path
      link = Nokogiri::HTML(response.body).at_css(%(a[href="#{member_knowledge_page_path(page)}"]))
      expect(link).to be_present
      expect(link["data-turbo-frame"]).to eq("_top")
    end
  end

  # CYRA-768 Scenario 2 — una pagina oltre la data di rilettura si trova comunque: nasconderla
  # sarebbe peggio che mostrarla marcata.
  describe "GET /member/knowledge/pages — pagine da rileggere" do
    def scaduta(titolo:)
      create(:knowledge_page, :decision, organization: org, project: project, title: titolo)
        .tap { |page| page.update_columns(review_after: 1.day.ago) }
    end

    it "la trova cercandola e la segna come da rivedere" do
      scaduta(titolo: "Scelta del proxy")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "proxy", semantic: "0" }

      expect(response.body).to include("Scelta del proxy")
      expect(response.body).to include('data-test="knowledge-needs-review-badge"')
    end

    it "il chip di testata conta quante pagine aspettano una rilettura" do
      scaduta(titolo: "Scelta del proxy")
      sign_in(member)

      get member_knowledge_pages_path

      chip = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-count-needs-review"]')
      expect(chip.text).to include("1")
    end

    it "una pagina ancora nei termini non porta nessun segno e non alza il chip" do
      futura = create(:knowledge_page, :decision, organization: org, project: project, title: "Ancora fresca")
      futura.update_columns(review_after: 30.days.from_now)
      sign_in(member)

      get member_knowledge_pages_path

      expect(response.body).to include("Ancora fresca")
      expect(response.body).not_to include('data-test="knowledge-needs-review-badge"')
      expect(response.body).not_to include('data-test="knowledge-count-needs-review"')
    end
  end

  # CYRA-419 — dopo l'accettazione non restava traccia di come la pagina fosse nata, e la colonna
  # Autore mostrava il nome della persona il cui accesso era stato usato.
  describe "GET /member/knowledge/pages — chi ha scritto la pagina" do
    it "il segno «Assistente» resta in elenco anche dopo l'accettazione" do
      create(:knowledge_page, :written_by_agent, organization: org, project: project, title: "Trappola dei worktree")
      sign_in(member)

      get member_knowledge_pages_path

      expect(response.body).to include('data-test="knowledge-agent-badge"')
      expect(response.body).to include(I18n.t("member.knowledge.author.agent_short"))
    end

    it "la colonna dell'autore dice chi ha scritto e con l'accesso di chi, non solo il nome della persona" do
      create(:knowledge_page, :written_by_agent, organization: org, project: project,
                                                 title: "Trappola dei worktree", created_by: member)
      sign_in(member)

      get member_knowledge_pages_path

      cella = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-author-cell"]').text
      expect(cella).to include("kb-inbox")
      expect(cella).to include(I18n.t("member.knowledge.author.on_behalf_of", account: member.name))
    end

    it "una pagina scritta da una persona non porta nessun segno" do
      create(:knowledge_page, :written_by_human, organization: org, project: project, title: "Setup ambienti")
      sign_in(member)

      get member_knowledge_pages_path

      expect(response.body).not_to include('data-test="knowledge-agent-badge"')
    end

    it "il filtro «Scritta da» isola le pagine di un assistente" do
      da_assistente = create(:knowledge_page, :written_by_agent, organization: org, project: project, title: "Trappola dei worktree")
      da_persona = create(:knowledge_page, :written_by_human, organization: org, project: project, title: "Setup ambienti")
      sign_in(member)

      get member_knowledge_pages_path, params: { author: [ "agent" ] }

      expect(response.body).to include(da_assistente.title)
      expect(response.body).not_to include(da_persona.title)
    end

    it "il filtro isola anche le pagine di cui non sappiamo chi le ha scritte" do
      legacy = create(:knowledge_page, organization: org, project: project, title: "Pagina di prima")
      da_assistente = create(:knowledge_page, :written_by_agent, organization: org, project: project, title: "Trappola dei worktree")
      sign_in(member)

      get member_knowledge_pages_path, params: { author: [ Knowledge::Page::UNREGISTERED_AUTHOR ] }

      expect(response.body).to include(legacy.title)
      expect(response.body).not_to include(da_assistente.title)
    end

    it "un filtro senza risultati spiega che non c'è match, non che la knowledge è vuota" do
      create(:knowledge_page, :written_by_human, organization: org, project: project, title: "Setup ambienti")
      sign_in(member)

      get member_knowledge_pages_path, params: { author: [ "agent" ] }

      expect(response.body).to include('data-test="knowledge-no-results"')
    end

    it "il dettaglio dice chi ha scritto, con l'accesso di chi, e quando il segno decade" do
      page = create(:knowledge_page, :written_by_agent, organization: org, project: project,
                                                        title: "Trappola dei worktree", created_by: member)
      sign_in(member)

      get member_knowledge_page_path(page)

      riquadro = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-spec-written-by"]').text
      expect(riquadro).to include(I18n.t("member.knowledge.author.agent_with_origin", origin: "kb-inbox"))
      expect(riquadro).to include(I18n.t("member.knowledge.author.on_behalf_of", account: member.name))
      expect(riquadro).to include(I18n.t("member.knowledge.author.agent_hint"))
    end

    it "sul dettaglio di una pagina di prima dice che non lo sappiamo, non che l'ha scritta una persona" do
      page = create(:knowledge_page, organization: org, project: project, title: "Pagina di prima")
      sign_in(member)

      get member_knowledge_page_path(page)

      riquadro = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-spec-written-by"]').text
      expect(riquadro).to include(I18n.t("member.knowledge.author.unregistered"))
      expect(riquadro).not_to include(I18n.t("member.knowledge.author.human"))
    end
  end

  describe "GET /member/knowledge/pages — stati vuoti e ricerca a zero risultati (CYRA-412)" do
    # Valore del chip di testata (StatLabelComponent): lo span monospace col numero.
    def chip_value(body, test_id)
      Nokogiri::HTML(body).at_css(%([data-test="#{test_id}"] span.font-mono))&.text&.strip
    end

    it "Scenario 2: knowledge base davvero vuota → invito a creare la prima pagina" do
      sign_in(member)

      get member_knowledge_pages_path

      expect(response.body).to include('data-test="knowledge-empty"')
      expect(response.body).not_to include('data-test="knowledge-no-results"')
      expect(response.body).to include(I18n.t("member.knowledge.empty"))
    end

    it "Scenario 1: ricerca senza risultati con pagine presenti → non dice mai che è vuota" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy")
      create(:knowledge_page, organization: org, project: project, title: "Onboarding")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "inesistentexyz" }

      # Stato "nessun risultato", MAI l'empty di primo accesso ("vuota").
      expect(response.body).to include('data-test="knowledge-no-results"')
      expect(response.body).not_to include('data-test="knowledge-empty"')
      expect(response.body).not_to include(I18n.t("member.knowledge.empty_body"))
    end

    it "Scenario 1: il messaggio riporta la parola cercata e quante pagine esistono in totale" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy")
      create(:knowledge_page, organization: org, project: project, title: "Onboarding")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "inesistentexyz" }

      title = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-no-results"] [data-test="no-results-title"]')
      expect(title.text).to include("inesistentexyz")
      body = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-no-results"]')
      expect(body.text).to include("2") # totale complessivo delle pagine visibili
    end

    it "Scenario 1: dallo stato di zero risultati si toglie la ricerca con un clic" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "inesistentexyz" }

      clear = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-no-results-clear"]')
      expect(clear).to be_present
      expect(URI(clear["href"]).path).to eq(member_knowledge_pages_path)
      expect(clear["data-turbo-frame"]).to eq("_top") # ricarica anche la barra di ricerca, non solo il frame
    end

    it "Scenario 1: offre di creare una pagina con quel titolo e di chiedere alla KB con la stessa query" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "backup postgres" }

      create_link = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-no-results-create"]')
      expect(create_link["href"]).to eq(new_member_knowledge_page_path(title: "backup postgres"))
      ask_link = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-no-results-ask"]')
      expect(ask_link["href"]).to eq(ask_member_knowledge_pages_path(q: "backup postgres"))
    end

    it "Scenario 3: i contatori di testata restano il quadro complessivo e coerenti tra loro sotto ricerca" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy")
      create(:knowledge_page, :decision, organization: org, project: project, title: "Decisione deploy")
      sign_in(member)

      # Senza ricerca: 2 pagine, 1 decisione (quadro complessivo).
      get member_knowledge_pages_path
      expect(chip_value(response.body, "knowledge-count-pages")).to eq("2")
      expect(chip_value(response.body, "knowledge-count-decisions")).to eq("1")

      # Con una ricerca che filtra la lista i chip NON divergono: nessuno scende a zero mentre l'altro
      # resta al totale (il bug). Si riferiscono tutti allo stesso insieme — tutte le pagine, non i
      # risultati — così restano coerenti anche via Turbo, dove l'header fuori dal frame non si aggiorna.
      get member_knowledge_pages_path, params: { q: "Guida" }
      expect(chip_value(response.body, "knowledge-count-pages")).to eq("2")
      expect(chip_value(response.body, "knowledge-count-decisions")).to eq("1")
    end

    it "Scenario 3: il totale nei chip coincide col totale dichiarato nel messaggio di zero risultati" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy")
      create(:knowledge_page, organization: org, project: project, title: "Onboarding")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "inesistentexyz" }

      # Niente header a "0 pagine" che contraddice il messaggio "ci sono 2 pagine…": chip e messaggio concordano.
      expect(chip_value(response.body, "knowledge-count-pages")).to eq("2")
      expect(Nokogiri::HTML(response.body).at_css('[data-test="knowledge-no-results"]').text).to include("2")
    end

    it "un filtro senza risultati (nessuna query) mostra comunque 'nessun risultato', non 'vuota'" do
      create(:knowledge_page, organization: org, project: project, title: "Solo una nota")
      sign_in(member)

      get member_knowledge_pages_path, params: { kind: [ "decision" ] }

      expect(response.body).to include('data-test="knowledge-no-results"')
      expect(response.body).not_to include('data-test="knowledge-empty"')
    end
  end

  describe "GET /member/knowledge/pages/new — rimbalzo da zero risultati (CYRA-412)" do
    it "pre-popola il titolo dal parametro title" do
      sign_in(member)

      get new_member_knowledge_page_path(title: "backup postgres")

      field = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-form-title"] input, input[name="title"]')
      expect(field["value"]).to eq("backup postgres")
    end
  end

  describe "GET /member/knowledge/pages/ask — rimbalzo da zero risultati (CYRA-412)" do
    it "pre-popola la domanda dal parametro q" do
      sign_in(member)

      get ask_member_knowledge_pages_path(q: "come faccio il backup?")

      textarea = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-ask-input"]')
      expect(textarea.text).to include("come faccio il backup?")
    end
  end

  describe "GET /member/knowledge/pages (semantica)" do
    around do |example|
      old_url = ENV["EMBED_BASE_URL"]
      old_key = ENV["AI_API_KEY"]
      ENV["EMBED_BASE_URL"] = "http://embed.test:7997"
      ENV["AI_API_KEY"] = "test-key"
      example.run
    ensure
      old_url ? ENV["EMBED_BASE_URL"] = old_url : ENV.delete("EMBED_BASE_URL")
      old_key ? ENV["AI_API_KEY"] = old_key : ENV.delete("AI_API_KEY")
    end

    it "Scenario 1: la ricerca di default è per significato (senza param semantic)" do
      near = create(:knowledge_page, organization: org, project: project, title: "Gestione delle code in ritardo")
      near.update_columns(embedding: basis_vector(0), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
      far = create(:knowledge_page, organization: org, project: project, title: "Palette colori")
      far.update_columns(embedding: basis_vector(1), embedding_checksum: "x",
                         embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)

      stub_request(:post, "http://embed.test:7997/embeddings")
        .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => basis_vector(0) } ] }.to_json)
      stub_request(:post, "http://embed.test:7997/rerank")
        .to_return(status: 200, body: { "results" => [ { "index" => 0, "relevance_score" => 0.9 } ] }.to_json)

      sign_in(member)
      # Parole diverse dal titolo, NESSUN param semantic: la modalità predefinita capisce il significato.
      get member_knowledge_pages_path, params: { q: "attività lente in coda" }

      expect(response.body).to include("Gestione delle code in ritardo")
      expect(response.body).not_to include("Palette colori")
    end

    it "Scenario 2: sopra i risultati dichiara la modalità in uso ed è reversibile con un clic" do
      page = create(:knowledge_page, organization: org, project: project, title: "Backup database")
      page.update_columns(embedding: basis_vector(0), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
      stub_request(:post, "http://embed.test:7997/embeddings")
        .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => basis_vector(0) } ] }.to_json)
      stub_request(:post, "http://embed.test:7997/rerank")
        .to_return(status: 200, body: { "results" => [ { "index" => 0, "relevance_score" => 0.9 } ] }.to_json)

      sign_in(member)
      get member_knowledge_pages_path, params: { q: "backup", semantic: "1" }

      banner = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-search-mode-banner"]')
      expect(banner).to be_present
      expect(banner.text).to include(I18n.t("member.knowledge.semantic.using_semantic"))
      # Link per passare a «parole esatte» (reversibile) che esce dal frame per riallineare la barra.
      switch = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-search-mode-switch"]')
      expect(switch["href"]).to include("semantic=0")
      expect(switch["data-turbo-frame"]).to eq("_top")
    end

    it "Scenario 2: in «parole esatte» il banner dichiara la modalità e offre il ritorno al significato" do
      create(:knowledge_page, organization: org, project: project, title: "Backup database")
      sign_in(member)
      get member_knowledge_pages_path, params: { q: "backup", semantic: "0" }

      banner = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-search-mode-banner"]')
      expect(banner.text).to include(I18n.t("member.knowledge.semantic.using_exact"))
      switch = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-search-mode-switch"]')
      expect(switch["href"]).to include("semantic=1")
    end

    it "no regressione: in «per significato» trova comunque una pagina col titolo che corrisponde ma senza embedding" do
      # Pagina appena creata: il job di embedding asincrono non è ancora girato (embedding nil).
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy Kamal")
      # Servizio embedding SU: il ramo semantico NON degrada, ma non ha candidati con embedding.
      stub_request(:post, "http://embed.test:7997/embeddings")
        .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => basis_vector(0) } ] }.to_json)
      stub_request(:post, "http://embed.test:7997/rerank")
        .to_return(status: 200, body: { "results" => [] }.to_json)

      sign_in(member)
      get member_knowledge_pages_path, params: { q: "deploy", semantic: "1" }

      # Prima si perdeva: il semantico scarta le pagine senza embedding. Ora il match sul titolo la salva.
      expect(response.body).to include("Guida deploy Kamal")
      expect(response.body).not_to include('data-test="knowledge-no-results"')
    end

    it "ordina per pertinenza col toggle attivo" do
      near = create(:knowledge_page, organization: org, project: project, title: "Backup database")
      near.update_columns(embedding: basis_vector(0), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
      far = create(:knowledge_page, organization: org, project: project, title: "Palette colori")
      far.update_columns(embedding: basis_vector(1), embedding_checksum: "x",
                         embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)

      stub_request(:post, "http://embed.test:7997/embeddings")
        .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => basis_vector(0) } ] }.to_json)
      stub_request(:post, "http://embed.test:7997/rerank")
        .to_return(status: 200, body: { "results" => [ { "index" => 0, "relevance_score" => 0.9 } ] }.to_json)

      sign_in(member)
      get member_knowledge_pages_path, params: { q: "come backuppo il db", semantic: "1" }

      expect(response.body).to include("Backup database")
      expect(response.body).not_to include("Palette colori")
    end

    it "servizio giù → fallback ILIKE con hint degradato" do
      create(:knowledge_page, organization: org, project: project, title: "Backup database")
      stub_request(:post, "http://embed.test:7997/embeddings").to_timeout

      sign_in(member)
      get member_knowledge_pages_path, params: { q: "Backup", semantic: "1" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"knowledge-semantic-degraded\"")
      expect(response.body).to include("Backup database")
    end

    # CYRA-573 — il ripiego è la stessa ricerca testuale della modalità «parole esatte»: se guardasse
    # i soli titoli, una parola scritta nel corpo sparirebbe proprio quando il significato non è
    # disponibile, cioè nel momento in cui l'utente ha meno alternative.
    it "servizio giù → il ripiego trova la parola scritta nel corpo, non solo nei titoli" do
      create(:knowledge_page, organization: org, project: project, title: "Onboarding",
                              body: "Il ripristino parte dallo snapshot notturno di rembrandt.")
      stub_request(:post, "http://embed.test:7997/embeddings").to_timeout

      sign_in(member)
      get member_knowledge_pages_path, params: { q: "rembrandt", semantic: "1" }

      expect(response.body).to include("data-test=\"knowledge-semantic-degraded\"")
      expect(response.body).to include("Onboarding")
      expect(response.body).not_to include('data-test="knowledge-no-results"')
    end
  end

  # CYRA-573 — «Parole esatte» guardava soltanto i titoli senza dirlo: una parola scritta nel corpo
  # non si trovava e al suo posto compariva l'invito a creare una pagina che esisteva già. Il modulo
  # di scrittura prometteva il contrario («entra nella ricerca come il contenuto semplice») e il
  # vettore semantico legge da sempre titolo, corpo e parte tecnica: due modalità sullo stesso
  # archivio guardavano insiemi diversi.
  describe "GET /member/knowledge/pages — «parole esatte» guarda tutto il testo (CYRA-573)" do
    it "Scenario 1: una parola scritta nel corpo trova la pagina, invece di proporne una nuova" do
      create(:knowledge_page, organization: org, project: project, title: "Onboarding",
                              body: "Il ripristino parte dallo snapshot notturno di rembrandt.")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "rembrandt", semantic: "0" }

      expect(response.body).to include("Onboarding")
      expect(response.body).not_to include('data-test="knowledge-no-results"')
    end

    it "anche la parte tecnica entra nella ricerca, come promette il modulo di scrittura" do
      create(:knowledge_page, :with_tech_spec, organization: org, project: project, title: "Ricerca interna")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "vector_cosine_ops", semantic: "0" }

      expect(response.body).to include("Ricerca interna")
      expect(response.body).not_to include('data-test="knowledge-no-results"')
    end

    it "il titolo continua a valere, e chi non contiene quelle parole resta fuori" do
      create(:knowledge_page, organization: org, project: project, title: "Guida deploy",
                              body: "Niente di attinente.")
      create(:knowledge_page, organization: org, project: project, title: "Onboarding",
                              body: "Niente di attinente.")
      sign_in(member)

      get member_knowledge_pages_path, params: { q: "deploy", semantic: "0" }

      expect(response.body).to include("Guida deploy")
      expect(response.body).not_to include("Onboarding")
    end

    # Guard sulla promessa: finché la ricerca guarda tutto il testo, nessuno dei due messaggi può
    # tornare a dire «per titolo» — era proprio la frase che raccontava una cosa diversa da quella
    # che il prodotto faceva, e nell'altro verso (testo che promette, ricerca che guarda i titoli)
    # è il difetto da cui nasce questo ticket.
    it "né il banner né l'avviso di ripiego promettono i soli titoli, in italiano e in inglese" do
      %i[it en].each do |locale|
        expect(I18n.t("member.knowledge.semantic.using_exact", locale:)).not_to match(/titol|title/i)
        expect(I18n.t("member.knowledge.semantic.degraded_hint", locale:)).not_to match(/titol|title/i)
      end
    end
  end

  describe "GET /member/knowledge/pages/:id" do
    it "keeps the page inside the content column, so the footer stays below it" do
      page = create(:knowledge_page, organization: org, project: project, title: "Balanced")
      sign_in(owner)
      get member_knowledge_page_path(page)

      footer = Nokogiri::HTML(response.body).at_css("[data-test='member-footer']")
      expect(footer.parent["class"]).to include("flex-col")
    end

    it "renderizza il markdown della pagina" do
      page = create(:knowledge_page, organization: org, project: project,
                                     title: "Guida", body: "## Sezione\n\nTesto **forte**.")
      sign_in(member)

      get member_knowledge_page_path(page)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sezione</h2>")
      expect(response.body).to include("<strong>forte</strong>")
    end

    # CYRA-434 — la colonna di destra parlava al sistema. «Indicizzata» è una parola da addetti, e
    # chi legge vuole sapere una cosa sola: se l'assistente userà questa pagina per rispondere.
    describe "colonna di destra (CYRA-434)" do
      it "dice in parole semplici che l'assistente può usare la pagina" do
        page = create(:knowledge_page, organization: org, project: project, embedded_at: Time.current)
        sign_in(member)

        get member_knowledge_page_path(page)

        stato = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-spec-assistant"]')
        expect(stato.text).to include(I18n.t("member.knowledge.show.assistant_ready"))
        # Il vecchio riquadro «Ricerca: Indicizzata» non c'è più: era il nome interno del meccanismo.
        expect(response.body).not_to include('data-test="knowledge-spec-index"')
      end

      it "una pagina non ancora indicizzata dice che l'assistente non la usa ancora" do
        page = create(:knowledge_page, organization: org, project: project, embedded_at: nil)
        sign_in(member)

        get member_knowledge_page_path(page)

        stato = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-spec-assistant"]')
        expect(stato.text).to include(I18n.t("member.knowledge.show.assistant_not_yet"))
      end

      it "il contatore dei caratteri sparisce dalla lettura e resta il tempo di lettura" do
        page = create(:knowledge_page, organization: org, project: project, body: "Testo breve.")
        sign_in(member)

        get member_knowledge_page_path(page)

        expect(response.body).not_to include('data-test="knowledge-spec-length-chars"')
        lunghezza = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-spec-length"]')
        expect(lunghezza.text).to include(I18n.t("member.knowledge.show.length_value", words: 2, minutes: 1))
      end

      # Il tetto del corpo si dichiarava solo col contatore, cioè si scopriva leggendo (o col
      # salvataggio rifiutato): ora è scritto dove si scrive, prima di battere il primo carattere.
      it "il tetto del corpo è dichiarato nell'editor" do
        page = create(:knowledge_page, organization: org, project: project, created_by: owner)
        sign_in(owner)

        get edit_member_knowledge_page_path(page)

        expect(response.body).to include(
          ERB::Util.html_escape(
            I18n.t("member.knowledge.form.body_limit", max: Knowledge::Constants::BODY_MAX_CHARS)
          )
        )
      end

      it "l'identificativo è solo un bottone che lo copia, non una riga di codice" do
        page = create(:knowledge_page, organization: org, project: project)
        sign_in(member)

        get member_knowledge_page_path(page)

        blocco = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-spec-id"]')
        expect(blocco.at_css('[data-test="knowledge-spec-id-copy"]')).to be_present
        # Il valore resta nel DOM (serve a copiarlo) ma non occupa una riga sotto gli occhi.
        sorgente = blocco.at_css('[data-clipboard-target="source"]')
        expect(sorgente.text).to eq(page.id)
        expect(sorgente.key?("hidden")).to be(true)
      end

      it "l'eliminazione sta in un menù con conferma, non accanto a Modifica" do
        page = create(:knowledge_page, organization: org, project: project, created_by: owner)
        sign_in(owner)

        get member_knowledge_page_path(page)

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css('[data-test="knowledge-edit"]')).to be_present
        menu = doc.at_css('[data-test="knowledge-more-menu"]')
        expect(menu).to be_present
        elimina = menu.at_css('[data-test="knowledge-delete"]')
        expect(elimina["data-turbo-confirm"]).to eq(I18n.t("member.knowledge.delete_confirm"))
        # Un solo Elimina in pagina, e sta dentro il menu: non è rimasto in barra.
        expect(doc.css('[data-test="knowledge-delete"]').size).to eq(1)
      end

      it "il riquadro degli allegati si riduce a una riga quando non ce n'è nessuno" do
        page = create(:knowledge_page, organization: org, project: project, created_by: owner)
        sign_in(owner)

        get member_knowledge_page_path(page)

        card = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-attachments"]')
        riga = card.at_css('[data-test="knowledge-attachments-empty"]')
        # Una riga sola: il "non ce n'è nessuno" e il comando per aggiungere stanno insieme, senza
        # il riquadro tratteggiato alto mezzo schermo che occupava la colonna a vuoto.
        expect(riga.at_css('[data-test="attachment-upload-form"]')).to be_present
        expect(card.at_css('[data-test="attachment-dropzone"]')).to be_nil
        expect(card.at_css('[data-test="attachment-upload-input"]')).to be_present
      end

      it "con un allegato il riquadro torna disteso, con la zona di trascinamento" do
        page = create(:knowledge_page, organization: org, project: project, created_by: owner)
        create(:knowledge_attachment, page: page, created_by: owner, title: "procedura.pdf")
        sign_in(owner)

        get member_knowledge_page_path(page)

        card = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-attachments"]')
        expect(card.at_css('[data-test="attachment-dropzone"]')).to be_present
        expect(card.at_css('[data-test="knowledge-attachments-empty"]')).to be_nil
      end
    end

    it "pagina di progetto non visibile → 404 (anti-BOLA)" do
      hidden = create(:knowledge_page, organization: org, project: create(:project, organization: org))
      sign_in(member)

      get member_knowledge_page_path(hidden)
      expect(response).to have_http_status(:not_found)
    end

    it "il corpo markdown ha una measure leggibile (max-w-[70ch]), non max-w-none" do
      page = create(:knowledge_page, organization: org, project: project, title: "Guida")
      sign_in(member)

      get member_knowledge_page_path(page)
      body_wrap = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-body"] .prose')
      expect(body_wrap["class"]).to include("max-w-[70ch]")
      expect(body_wrap["class"]).not_to include("max-w-none")
    end

    describe "collegamenti fra pagine" do
      let!(:target) { create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal") }
      let!(:source) do
        create(:knowledge_page, organization: org, project: project, title: "Rollback",
                                body: "Segue [[Deploy Kamal]].").tap { |page| Knowledge::Links::Sync.call(page: page) }
      end

      it "rende cliccabile il wikilink risolto nel corpo" do
        sign_in(member)

        get member_knowledge_page_path(source)

        link = Nokogiri::HTML(response.body).at_css("[data-test=\"knowledge-body\"] a[href=\"#{member_knowledge_page_path(target)}\"]")
        expect(link.text).to eq("Deploy Kamal")
      end

      it "mostra la card Collegate sulla sorgente e Citata da sulla destinazione" do
        sign_in(member)

        get member_knowledge_page_path(source)
        outgoing = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-links-outgoing"]')
        expect(outgoing.text).to include("Deploy Kamal")

        get member_knowledge_page_path(target)
        incoming = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-links-incoming"]')
        expect(incoming.text).to include("Rollback")
      end

      # CYRA-433 Scenario 3: senza collegamenti la card resta e insegna a cosa serve — è l'unico
      # punto in cui chi non ha letto la guida scopre che le pagine si possono collegare.
      it "senza collegamenti la card c'è lo stesso e spiega come si collega una pagina" do
        lonely = create(:knowledge_page, organization: org, project: project, title: "Isolata")
        sign_in(member)

        get member_knowledge_page_path(lonely)

        expect(response.body).to include('data-test="knowledge-links"')
        empty = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-links-empty"]')
        expect(empty).to be_present
        expect(empty.text).to include(I18n.t("member.knowledge.show.links_empty"))
        expect(empty.text).to include(I18n.t("member.knowledge.show.links_syntax"))
        # Le due liste non esistono: nulla da mostrare, nessuna intestazione vuota.
        expect(response.body).not_to include('data-test="knowledge-links-outgoing"')
        expect(response.body).not_to include('data-test="knowledge-links-incoming"')
      end

      it "ANTI-LEAK: un collegamento verso un progetto non visibile non è né linkato né in card" do
        hidden_project = create(:project, organization: org)
        hidden = create(:knowledge_page, organization: org, project: hidden_project, title: "Riservata")
        citing = create(:knowledge_page, organization: org, project: project, title: "Cita altrove",
                                         body: "Vedi [[Riservata]].")
        Knowledge::Links::Sync.call(page: citing)
        expect(citing.links.reload.map(&:related)).to eq([ hidden ])

        sign_in(member)
        get member_knowledge_page_path(citing)

        # Il wikilink resta testo semplice: nessun link morto verso una pagina non apribile.
        # (Il titolo si legge nel corpo perché l'ha scritto l'autore stesso, non perché trapeli.)
        expect(response.body).not_to include(member_knowledge_page_path(hidden))
        # La card c'è (CYRA-433) ma è nello stato vuoto: il collegamento nascosto non compare.
        expect(response.body).to include('data-test="knowledge-links-empty"')
        expect(response.body).not_to include('data-test="knowledge-links-outgoing"')
      end
    end
  end

  describe "GET show — il book che contiene la pagina (CYRA-415)" do
    it "mostra il book a cui la pagina appartiene, con collegamento (Scenario 3)" do
      book = create(:knowledge_book, organization: org, project: project, title: "Manuale onboarding")
      page = create(:knowledge_page, organization: org, project: project, title: "Setup ambienti", book: book)
      sign_in(member)

      get member_knowledge_page_path(page)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="knowledge-spec-book"')
      expect(response.body).to include("Manuale onboarding")
      expect(response.body).to include(member_knowledge_book_path(book))
    end

    it "ANTI-LEAK: non mostra il book se scoped a progetti che l'utente non vede" do
      hidden_project = create(:project, organization: org)
      book = create(:knowledge_book, organization: org, project: hidden_project, title: "Manuale nascosto")
      # La pagina resta visibile al member (collegata anche al progetto visibile), ma il book no.
      page = create(:knowledge_page, organization: org, project: project, title: "Pagina condivisa", book: book)
      sign_in(member)

      get member_knowledge_page_path(page)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Manuale nascosto")
      expect(response.body).not_to include('data-test="knowledge-spec-book"')
    end

    it "non mostra la sezione book quando la pagina non è in nessun book" do
      page = create(:knowledge_page, organization: org, project: project, title: "Pagina libera")
      sign_in(member)

      get member_knowledge_page_path(page)

      expect(response.body).not_to include('data-test="knowledge-spec-book"')
    end
  end

  describe "GET /member/knowledge/pages/new + edit" do
    it "new risponde con 200" do
      sign_in(member)
      get new_member_knowledge_page_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"knowledge-form\"")
    end

    it "edit risponde con 200 per l'autore" do
      page = create(:knowledge_page, organization: org, project: project, created_by: member)
      sign_in(member)
      get edit_member_knowledge_page_path(page)
      expect(response).to have_http_status(:ok)
    end

    # CYRA-433 Scenario 1: la sintassi del collegamento si legge dove si scrive, non solo nella guida.
    it "sotto il campo contenuto spiega come si collega un'altra pagina" do
      sign_in(member)
      get new_member_knowledge_page_path

      hint = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-form-links-hint"]')
      expect(hint).to be_present
      expect(hint.text).to include(I18n.t("member.knowledge.form.links_hint"))
      expect(hint.text).to include("[[")
    end

    it "arma il suggerimento dei titoli sul campo contenuto" do
      sign_in(member)
      get new_member_knowledge_page_path

      field = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-form-body"]')
      expect(field["data-knowledge-links-target"]).to eq("field")
      wrapper = field.ancestors('[data-controller~="knowledge-links"]').first
      expect(wrapper).to be_present
      expect(wrapper["data-knowledge-links-url-value"]).to eq(link_suggestions_member_knowledge_pages_path)
    end

    it "in modifica esclude la pagina corrente dai titoli suggeriti" do
      page = create(:knowledge_page, organization: org, project: project, created_by: member)
      sign_in(member)
      get edit_member_knowledge_page_path(page)

      wrapper = Nokogiri::HTML(response.body).at_css('[data-controller~="knowledge-links"]')
      expect(wrapper["data-knowledge-links-exclude-id-value"]).to eq(page.id)
    end
  end

  describe "POST /member/knowledge/pages" do
    it "crea la pagina e reindirizza alla show" do
      sign_in(member)
      expect {
        post member_knowledge_pages_path, params: { project_ids: [ project.id ], title: "Nuova nota",
                                                    body: "Testo", kind: "note" }
      }.to change(Knowledge::Page, :count).by(1)
      expect(response).to redirect_to(member_knowledge_page_path(Knowledge::Page.last))
    end

    it "pagina invalida → 422 col form ripresentato" do
      sign_in(member)
      post member_knowledge_pages_path, params: { project_ids: [ project.id ], title: "", body: "" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("data-test=\"knowledge-form\"")
    end

    it "corpo oltre il limite → 422 col messaggio che dice quanto è lungo" do
      sign_in(member)

      expect {
        post member_knowledge_pages_path,
             params: { project_ids: [ project.id ], title: "Troppo lunga",
                       body: "x" * (Knowledge::Constants::BODY_MAX_CHARS + 1), kind: "note" }
      }.not_to change(Knowledge::Page, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("data-test=\"knowledge-form-body-error\"")
      expect(response.body).to include((Knowledge::Constants::BODY_MAX_CHARS + 1).to_s)
    end

    it "salva la sezione tecnica dal form" do
      sign_in(member)
      post member_knowledge_pages_path, params: { project_ids: [ project.id ], title: "Con tecnico",
                                                  body: "Testo", kind: "note", tech_spec: "Dettagli tecnici." }
      expect(Knowledge::Page.last.tech_spec).to eq("Dettagli tecnici.")
    end
  end

  describe "PATCH /member/knowledge/pages/:id" do
    let(:page) { create(:knowledge_page, organization: org, project: project, created_by: member) }
    let(:foreign_page) { create(:knowledge_page, organization: org, project: project) }

    it "l'autore aggiorna la propria pagina" do
      sign_in(member)
      patch member_knowledge_page_path(page), params: { title: "Titolo nuovo", body: page.body, kind: page.kind }
      expect(page.reload.title).to eq("Titolo nuovo")
      expect(response).to redirect_to(member_knowledge_page_path(page))
    end

    it "un member senza knowledge.edit NON aggiorna la pagina altrui (403 → redirect)" do
      sign_in(member)
      patch member_knowledge_page_path(foreign_page), params: { title: "Hack", body: "x", kind: "note" }
      expect(response).to redirect_to(root_path)
      expect(foreign_page.reload.title).not_to eq("Hack")
    end

    it "l'owner aggiorna la pagina altrui" do
      sign_in(owner)
      patch member_knowledge_page_path(foreign_page), params: { title: "Aggiornata", body: foreign_page.body, kind: foreign_page.kind }
      expect(foreign_page.reload.title).to eq("Aggiornata")
    end

    it "l'autore aggiorna la sezione tecnica della propria pagina" do
      sign_in(member)
      patch member_knowledge_page_path(page),
            params: { title: page.title, body: page.body, kind: page.kind, tech_spec: "Nuovo tecnico." }
      expect(page.reload.tech_spec).to eq("Nuovo tecnico.")
    end
  end

  describe "DELETE /member/knowledge/pages/:id" do
    it "l'autore elimina la propria pagina; il member NON elimina l'altrui" do
      own = create(:knowledge_page, organization: org, project: project, created_by: member)
      foreign = create(:knowledge_page, organization: org, project: project)
      sign_in(member)

      expect { delete member_knowledge_page_path(own) }.to change(Knowledge::Page, :count).by(-1)
      expect { delete member_knowledge_page_path(foreign) }.not_to change(Knowledge::Page, :count)
    end
  end

  describe "pagine generali (org-wide) e tag" do
    it "un member NON vede una pagina generale org-wide (404)" do
      page = create(:knowledge_page, :org_wide, organization: org)
      sign_in(member)
      get member_knowledge_page_path(page)
      expect(response).to have_http_status(:not_found)
    end

    it "l'owner apre una pagina generale org-wide" do
      page = create(:knowledge_page, :org_wide, organization: org, title: "Decisione generale")
      sign_in(owner)
      get member_knowledge_page_path(page)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Decisione generale")
    end

    it "crea una pagina collegata a più progetti con tag" do
      other = create(:project, organization: org)
      create(:project_membership, account: member, project: other)
      sign_in(member)

      expect {
        post member_knowledge_pages_path, params: {
          project_ids: [ project.id, other.id ], title: "Sistema Flutter",
          body: "Decisioni comuni.", kind: "note", tags: "flutter, flutter-flavor"
        }
      }.to change(Knowledge::Page, :count).by(1)

      created = Knowledge::Page.last
      expect(created.projects).to contain_exactly(project, other)
      expect(created.tags).to eq(%w[flutter flutter-flavor])
    end

    it "filtra l'index per tag" do
      create(:knowledge_page, organization: org, project: project, title: "Pagina Flutter", tags: %w[flutter])
      create(:knowledge_page, organization: org, project: project, title: "Pagina Android", tags: %w[android])
      sign_in(member)

      get member_knowledge_pages_path, params: { tag: [ "flutter" ] }

      expect(response.body).to include("Pagina Flutter")
      expect(response.body).not_to include("Pagina Android")
    end

    it "una pagina collegata solo a un gruppo mostra il gruppo, non 'generale'" do
      group = create(:group, organization: org, name: "GruppoFlutter")
      create(:group_membership, account: member, group: group)
      create(:project, organization: org, group: group)
      page = create(:knowledge_page, :org_wide, organization: org, title: "Solo gruppo")
      page.groups << group
      sign_in(member)

      get member_knowledge_pages_path

      expect(response.body).to include("GruppoFlutter")
      expect(response.body).not_to include(I18n.t("member.knowledge.org_wide"))
    end
  end

  describe "gestione di pagine su un gruppo senza progetti (sicurezza)" do
    let(:empty_group) { create(:group, organization: org) } # nessun progetto dentro

    it "un membro del gruppo NON può modificare una pagina altrui collegata solo a quel gruppo" do
      create(:group_membership, account: member, group: empty_group)
      page = create(:knowledge_page, :org_wide, organization: org, title: "Originale") # autore: un altro
      page.groups << empty_group
      sign_in(member)

      patch member_knowledge_page_path(page), params: { title: "Hack", body: "x", kind: "note" }

      expect(response).to redirect_to(root_path)
      expect(page.reload.title).to eq("Originale")
    end

    it "un membro del gruppo NON può eliminare una pagina altrui collegata solo a quel gruppo" do
      create(:group_membership, account: member, group: empty_group)
      page = create(:knowledge_page, :org_wide, organization: org)
      page.groups << empty_group
      sign_in(member)

      expect { delete member_knowledge_page_path(page) }.not_to change(Knowledge::Page, :count)
    end

    it "l'owner (accesso pieno) può gestire una pagina collegata solo a un gruppo senza progetti" do
      page = create(:knowledge_page, :org_wide, organization: org, title: "Originale")
      page.groups << empty_group
      sign_in(owner)

      patch member_knowledge_page_path(page), params: { title: "Aggiornata", body: page.body, kind: page.kind }

      expect(page.reload.title).to eq("Aggiornata")
    end
  end

  it "non autenticato → redirect al login" do
    get member_knowledge_pages_path
    expect(response).to redirect_to(login_path)
  end
end
