# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Knowledge::Pages", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto ma senza chiavi knowledge.* → testa il 403 sulle pagine altrui.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  it "senza token → 401" do
    get "/cli/v1/knowledge/pages"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET /cli/v1/knowledge/pages" do
    it "lista le pagine visibili con meta; filtro kind e project (per key)" do
      note = create(:knowledge_page, organization:, project:, title: "Nota A")
      decision = create(:knowledge_page, :decision, organization:, project:, title: "Decisione B")

      get "/cli/v1/knowledge/pages", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |p| p["id"] }).to contain_exactly(note.id, decision.id)
      expect(response.parsed_body["meta"]).to include("total")

      get "/cli/v1/knowledge/pages", params: { kind: [ "decision" ] }, headers: headers
      expect(response.parsed_body["data"].map { |p| p["id"] }).to eq([ decision.id ])

      get "/cli/v1/knowledge/pages", params: { project: project.key.downcase }, headers: headers
      expect(response.parsed_body["data"].size).to eq(2)
    end

    it "esclude le pagine dei progetti non visibili (anti-BOLA) e 404 su project filter fuori scope" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      visible = create(:project, organization:)
      create(:project_membership, account: member, project: visible)
      create(:knowledge_page, organization:, project:, title: "Fuori scope")
      inside = create(:knowledge_page, organization:, project: visible, title: "Dentro")
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/knowledge/pages", headers: { "Authorization" => "Bearer #{member_secret}" }
      expect(response.parsed_body["data"].map { |p| p["id"] }).to eq([ inside.id ])

      get "/cli/v1/knowledge/pages", params: { project: project.key },
                                     headers: { "Authorization" => "Bearer #{member_secret}" }
      expect(response).to have_http_status(:not_found)
    end

    it "?q= senza servizio embedding → fallback ILIKE con meta.search=like" do
      create(:knowledge_page, organization:, project:, title: "Guida deploy")
      create(:knowledge_page, organization:, project:, title: "Altro")

      get "/cli/v1/knowledge/pages", params: { q: "deploy" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |p| p["title"] }).to eq([ "Guida deploy" ])
      expect(response.parsed_body["meta"]["search"]).to eq("like")
    end

    # CYRA-573: il ripiego testuale è lo stesso del canale web — titolo, corpo e parte tecnica. Un
    # canale che cerca solo nei titoli e uno che cerca in tutto il testo darebbero due risposte
    # diverse alla stessa domanda sullo stesso archivio.
    it "il fallback testuale guarda anche il corpo e la parte tecnica, non solo il titolo" do
      create(:knowledge_page, organization:, project:, title: "Onboarding",
                              body: "Il ripristino parte dallo snapshot notturno di rembrandt.")
      create(:knowledge_page, :with_tech_spec, organization:, project:, title: "Ricerca interna")
      create(:knowledge_page, organization:, project:, title: "Altro", body: "Niente di attinente.")

      get "/cli/v1/knowledge/pages", params: { q: "rembrandt" }, headers: headers
      expect(response.parsed_body["data"].map { |p| p["title"] }).to eq([ "Onboarding" ])

      get "/cli/v1/knowledge/pages", params: { q: "vector_cosine_ops" }, headers: headers
      expect(response.parsed_body["data"].map { |p| p["title"] }).to eq([ "Ricerca interna" ])
    end

    it "non enumera i progetti che il chiamante non vede (anti-leak)" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      hidden = create(:project, organization:) # il member NON lo vede
      shared = create(:knowledge_page, organization:, project:, title: "Condivisa")
      shared.projects << hidden
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/knowledge/pages", headers: { "Authorization" => "Bearer #{member_secret}" }

      row = response.parsed_body["data"].find { |p| p["id"] == shared.id }
      expect(row["projects"].map { |p| p["key"] }).to contain_exactly(project.key)
      expect(row["project"]).to eq(project.key)
    end
  end

  describe "GET /cli/v1/knowledge/pages/:id" do
    it "show con body completo e riferimenti umani" do
      page = create(:knowledge_page, :decision, organization:, project:, title: "Scelta DB", body: "PostgreSQL.")
      get "/cli/v1/knowledge/pages/#{page.id}", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to include("title" => "Scelta DB", "body" => "PostgreSQL.", "kind" => "decision",
                              "project" => project.key)
    end

    it "pagina fuori scope → 404" do
      other_org_page = create(:knowledge_page)
      get "/cli/v1/knowledge/pages/#{other_org_page.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "espone la sezione tecnica (tech_spec) nel payload" do
      page = create(:knowledge_page, :with_tech_spec, organization:, project:, title: "Con tecnico")
      get "/cli/v1/knowledge/pages/#{page.id}", headers: headers
      expect(response.parsed_body["data"]).to include("tech_spec" => page.tech_spec)
    end
  end

  describe "POST /cli/v1/knowledge/pages" do
    it "crea una pagina (project per key) → 201" do
      expect {
        post "/cli/v1/knowledge/pages",
             params: { project: project.key, title: "Runbook", body: "Passi.", kind: "guide" },
             headers: headers
      }.to change(Knowledge::Page, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["kind"]).to eq("guide")
    end

    it "crea una pagina collegata a più progetti via project_ids[] (multi-progetto)" do
      other = create(:project, organization:)

      post "/cli/v1/knowledge/pages",
           params: { project_ids: [ project.id, other.id ], title: "Sistema Flutter", body: "Comune." },
           headers: headers
      expect(response).to have_http_status(:created)

      created = Knowledge::Page.find(response.parsed_body["data"]["id"])
      expect(created.projects).to contain_exactly(project, other)
    end

    it "progetto inesistente → 404 envelope" do
      post "/cli/v1/knowledge/pages", params: { project: "NOPE", title: "X", body: "Y" }, headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-KNOWLEDGE-001")
    end

    # CYRA-419 — la proposta è di un assistente che sta usando l'accesso di una persona: la pagina
    # deve registrarlo, altrimenti in revisione risulta scritta da lei.
    describe "chi ha scritto il testo" do
      it "l'origine dichiarata dal chiamante finisce sulla pagina" do
        post "/cli/v1/knowledge/pages",
             params: { project: project.key, title: "Trappola", body: "Testo.", in_review: true, author_origin: "kb-inbox" },
             headers: headers

        created = Knowledge::Page.find(response.parsed_body["data"]["id"])
        expect(created).to be_written_by_agent
        expect(created.author_origin).to eq("kb-inbox")
        expect(created.created_by).to eq(account)
        expect(response.parsed_body["data"]).to include("author_kind" => "agent", "author_origin" => "kb-inbox")
      end

      it "senza dichiarazione, una proposta in revisione resta di un assistente ed è etichettata col canale usato" do
        post "/cli/v1/knowledge/pages",
             params: { project: project.key, title: "Trappola", body: "Testo.", in_review: true },
             headers: headers

        created = Knowledge::Page.find(response.parsed_body["data"]["id"])
        expect(created).to be_written_by_agent
        expect(created.author_origin).to eq("CLI")
      end

      it "una pagina pubblicata senza dichiarazione resta di origine non registrata, non attribuita a una persona" do
        post "/cli/v1/knowledge/pages",
             params: { project: project.key, title: "Runbook", body: "Passi." },
             headers: headers

        created = Knowledge::Page.find(response.parsed_body["data"]["id"])
        expect(created).to be_author_unregistered
        expect(created).not_to be_written_by_agent
      end
    end

    it "corpo oltre il limite → 422 envelope: la regola vale anche fuori dal web" do
      expect {
        post "/cli/v1/knowledge/pages",
             params: { project: project.key, title: "Troppo lunga",
                       body: "x" * (Knowledge::Constants::BODY_MAX_CHARS + 1) },
             headers: headers
      }.not_to change(Knowledge::Page, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-001")
      expect(response.parsed_body["error"]["details"]["body"].first)
        .to include(Knowledge::Constants::BODY_MAX_CHARS.to_s)
    end

    it "accetta e restituisce la sezione tecnica (generazione via agente CLI)" do
      post "/cli/v1/knowledge/pages",
           params: { project: project.key, title: "Runbook", body: "Passi.", tech_spec: "Comando: kamal deploy." },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["tech_spec"]).to eq("Comando: kamal deploy.")
      expect(Knowledge::Page.find(response.parsed_body["data"]["id"]).tech_spec).to eq("Comando: kamal deploy.")
    end
  end

  describe "PATCH update parziale della sezione tecnica (agente CLI)" do
    it "aggiorna solo tech_spec, versiona e non azzera il body" do
      page = create(:knowledge_page, organization:, project:, title: "T", body: "Corpo originale")

      patch "/cli/v1/knowledge/pages/#{page.id}",
            params: { tech_spec: "Nuovo tecnico da CLI." }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["tech_spec"]).to eq("Nuovo tecnico da CLI.")
      expect(page.reload.body).to eq("Corpo originale")
      expect(page.versions.count).to eq(1)
    end
  end

  describe "PATCH/DELETE su pagine altrui" do
    it "member senza chiavi → 403; owner → ok" do
      page = create(:knowledge_page, organization:, project:, title: "Di qualcun altro")

      patch "/cli/v1/knowledge/pages/#{page.id}",
            params: { title: "Hack", body: page.body, kind: page.kind }, headers: member_headers
      expect(response).to have_http_status(:forbidden)

      patch "/cli/v1/knowledge/pages/#{page.id}",
            params: { title: "Aggiornata", body: page.body, kind: page.kind }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(page.reload.title).to eq("Aggiornata")

      expect {
        delete "/cli/v1/knowledge/pages/#{page.id}", headers: headers
      }.to change(Knowledge::Page, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "POST /cli/v1/knowledge/ask" do
    it "risponde con citazioni serializzate" do
      page = create(:knowledge_page, organization:, project:, title: "Scelta DB")
      allow(Knowledge::AskPages).to receive(:call).and_return(
        Result.ok(Knowledge::AskPages::Answer.new(answer: "PostgreSQL", pages: [ page ], insufficient: false))
      )

      post "/cli/v1/knowledge/ask", params: { question: "che DB?" }, headers: headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["answer"]).to eq("PostgreSQL")
      expect(data["pages"].first["id"]).to eq(page.id)
    end

    it "servizio giù → errore envelope" do
      post "/cli/v1/knowledge/ask", params: { question: "che DB?" }, headers: headers
      expect(response).not_to have_http_status(:ok)
      expect(response.parsed_body["error"]).to include("code", "message")
    end

    it "aggiunge il secondo salto: ciò che le pagine citate collegano" do
      cited = create(:knowledge_page, organization:, project:, title: "Scelta DB")
      linked = create(:knowledge_page, organization:, project:, title: "Backup e restore")
      create(:page_link, page: cited, related: linked)
      allow(Knowledge::AskPages).to receive(:call).and_return(
        Result.ok(Knowledge::AskPages::Answer.new(answer: "PostgreSQL", pages: [ cited ], insufficient: false))
      )

      post "/cli/v1/knowledge/ask", params: { question: "che DB?" }, headers: headers

      related = response.parsed_body["data"]["related"]
      expect(related.map { |row| row["title"] }).to eq([ "Backup e restore" ])
      expect(related.first).to include("via" => "link")
    end
  end

  describe "pagine correlate" do
    let(:source) { create(:knowledge_page, organization:, project:, title: "Rollback", body: "Segue [[Deploy Kamal]].") }
    let(:target) { create(:knowledge_page, organization:, project:, title: "Deploy Kamal") }

    it "GET /:id senza ?related resta identica a prima (nessun costo, nessun meta)" do
      target
      get "/cli/v1/knowledge/pages/#{source.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("meta")
    end

    it "GET /:id?related=1 restituisce i collegamenti in meta.related" do
      target
      Knowledge::Links::Sync.call(page: source)

      get "/cli/v1/knowledge/pages/#{source.id}", params: { related: "1" }, headers: headers

      related = response.parsed_body["meta"]["related"]
      expect(related.map { |row| row["title"] }).to eq([ "Deploy Kamal" ])
      expect(related.first).to include("via" => "link", "project" => project.key, "relevance" => nil)
      expect(related.first).not_to have_key("body")
    end

    it "GET /:id/related elenca i collegamenti con la domanda in meta" do
      target
      Knowledge::Links::Sync.call(page: source)

      get "/cli/v1/knowledge/pages/#{source.id}/related",
          params: { question: "come annullo un rilascio?" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |row| row["title"] }).to eq([ "Deploy Kamal" ])
      expect(response.parsed_body["meta"]).to include("question" => "come annullo un rilascio?")
    end

    it "GET /:id/related su pagina fuori scope → 404" do
      get "/cli/v1/knowledge/pages/#{create(:knowledge_page).id}/related", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "l'indice con ?related=1 raggruppa i collegamenti per pagina" do
      target
      Knowledge::Links::Sync.call(page: source)

      get "/cli/v1/knowledge/pages", params: { related: "1" }, headers: headers

      grouped = response.parsed_body["meta"]["related"]
      expect(grouped.fetch(source.id).map { |row| row["title"] }).to eq([ "Deploy Kamal" ])
      # Il collegamento si vede da entrambi i lati: la citata mostra chi la cita.
      expect(grouped.fetch(target.id).map { |row| row["title"] }).to eq([ "Rollback" ])
    end

    it "l'indice senza ?related non porta collegamenti" do
      target
      Knowledge::Links::Sync.call(page: source)

      get "/cli/v1/knowledge/pages", headers: headers

      expect(response.parsed_body["meta"]).not_to have_key("related")
    end

    it "ANTI-LEAK: una pagina collegata in un progetto non visibile non compare mai" do
      hidden_project = create(:project, organization:)
      hidden = create(:knowledge_page, organization:, project: hidden_project, title: "Deploy Kamal")
      visible_source = create(:knowledge_page, organization:, project:, title: "Rollback",
                                               body: "Segue [[Deploy Kamal]].")
      Knowledge::Links::Sync.call(page: visible_source)
      expect(visible_source.links.reload.map(&:related)).to eq([ hidden ])

      get "/cli/v1/knowledge/pages/#{visible_source.id}/related", headers: member_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to be_empty
    end
  end

  # CYRA-769 — controllo dei doppioni in UNA ricerca sola. Chi propone una pagina deve poter vedere
  # anche le proposte in attesa e quelle già scartate: cercarle a parte, con altri due comandi, è la
  # causa tipica del doppione. Le pagine non pubblicate NON hanno embedding (Knowledge::CreatePage
  # non lo accoda di proposito), quindi col servizio embedding SU il solo ramo semantico non le
  # troverebbe mai — ed è esattamente lo stato in cui gira la produzione.
  describe "ricerca su tutti gli stati (CYRA-769)" do
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

    # Servizio embedding SU: il ramo semantico non degrada e `meta.search` resta "semantic".
    # Il rerank riceve solo i candidati CON embedding: dove non ce ne sono non viene nemmeno chiamato.
    def stub_embedding_service
      stub_request(:post, "http://embed.test:7997/embeddings")
        .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => basis_vector(0) } ] }.to_json)
      stub_request(:post, "http://embed.test:7997/rerank")
        .to_return(status: 200, body: { "results" => [ { "index" => 0, "relevance_score" => 0.9 } ] }.to_json)
    end

    def embedded!(page, index)
      page.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end

    it "Scenario 1: con ?status=all la ricerca trova anche la proposta in attesa e quella scartata" do
      proposta = create(:knowledge_page, :in_review, organization:, project:, title: "Trappola dei worktree")
      scartata = create(:knowledge_page, :rejected, organization:, project:, title: "Worktree e database")
      create(:knowledge_page, organization:, project:, title: "Palette colori")
      stub_embedding_service

      get "/cli/v1/knowledge/pages", params: { q: "worktree", status: "all" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |page| page["id"] }).to contain_exactly(proposta.id, scartata.id)
      expect(response.parsed_body["meta"]["search"]).to eq("semantic")
    end

    it "Scenario 1: anche chiedendo il solo stato in attesa la proposta si trova cercando" do
      proposta = create(:knowledge_page, :in_review, organization:, project:, title: "Trappola dei worktree")
      stub_embedding_service

      get "/cli/v1/knowledge/pages", params: { q: "worktree", status: "in_review" }, headers: headers

      expect(response.parsed_body["data"].map { |page| page["id"] }).to eq([ proposta.id ])
    end

    it "Scenario 2: senza chiedere nulla la ricerca continua a vedere solo le pagine accettate" do
      create(:knowledge_page, :in_review, organization:, project:, title: "Trappola dei worktree")
      create(:knowledge_page, :rejected, organization:, project:, title: "Worktree e database")
      pubblicata = create(:knowledge_page, organization:, project:, title: "Worktree condivisi")
      stub_embedding_service

      get "/cli/v1/knowledge/pages", params: { q: "worktree" }, headers: headers

      expect(response.parsed_body["data"].map { |page| page["id"] }).to eq([ pubblicata.id ])
    end

    it "Scenario 3: allargare gli stati non allarga i permessi" do
      fuori_scope = create(:project, organization:)
      nascosta = create(:knowledge_page, :in_review, organization:, project: fuori_scope,
                                                     title: "Trappola dei worktree")
      visibile = create(:knowledge_page, :in_review, organization:, project:, title: "Worktree condivisi")
      stub_embedding_service

      get "/cli/v1/knowledge/pages", params: { q: "worktree", status: "all" }, headers: member_headers

      ids = response.parsed_body["data"].map { |page| page["id"] }
      expect(ids).to eq([ visibile.id ])
      expect(ids).not_to include(nascosta.id)
    end

    # La coda testuale si aggiunge DOPO la pertinenza semantica: chi ha un embedding resta primo.
    it "l'ordine resta quello della pertinenza: prima il significato, poi le parole esatte" do
      vicina = create(:knowledge_page, organization:, project:, title: "Gestione delle copie di lavoro")
      embedded!(vicina, 0)
      proposta = create(:knowledge_page, :in_review, organization:, project:,
                                                     title: "Trappola delle copie di lavoro")
      stub_embedding_service

      get "/cli/v1/knowledge/pages", params: { q: "copie di lavoro", status: "all" }, headers: headers

      expect(response.parsed_body["data"].map { |page| page["id"] }).to eq([ vicina.id, proposta.id ])
    end

    it "nessuna corrispondenza resta una lista vuota, non l'archivio intero" do
      create(:knowledge_page, :in_review, organization:, project:, title: "Trappola dei worktree")
      stub_embedding_service

      get "/cli/v1/knowledge/pages", params: { q: "palette dei colori", status: "all" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to be_empty
    end
  end

  describe "revisione (CYRA-298)" do
    it "crea una proposta in revisione con la sua motivazione" do
      post "/cli/v1/knowledge/pages",
           params: { project: project.key, title: "Trappola dei worktree", body: "Il database è condiviso.",
                     in_review: true, review_note: "Trappola incontrata oggi." },
           headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["status"]).to eq("in_review")
      expect(response.parsed_body["data"]["review_note"]).to eq("Trappola incontrata oggi.")
    end

    it "la proposta resta fuori dall'elenco normale e dalla ricerca" do
      proposta = create(:knowledge_page, :in_review, organization:, project:, title: "Proposta")
      pubblicata = create(:knowledge_page, organization:, project:, title: "Pubblicata")

      get "/cli/v1/knowledge/pages", headers: headers
      expect(response.parsed_body["data"].map { |page| page["id"] }).to eq([ pubblicata.id ])

      get "/cli/v1/knowledge/pages", params: { q: "Proposta" }, headers: headers
      expect(response.parsed_body["data"].map { |page| page["id"] }).not_to include(proposta.id)
    end

    it "la proposta resta fuori dallo scope su cui risponde il RAG" do
      proposta = create(:knowledge_page, :in_review, organization:, project:, title: "Proposta")
      pubblicata = create(:knowledge_page, organization:, project:, title: "Pubblicata")
      asked_scope = nil
      # `organization:` viaggia con la domanda (CYRA-547): è chi paga la risposta.
      allow(Knowledge::AskPages).to receive(:call) do |scope:, question:, organization:| # rubocop:disable Lint/UnusedBlockArgument
        asked_scope = scope
        Result.ok(Knowledge::AskPages::Answer.new(answer: "ok", pages: [], insufficient: false))
      end

      post "/cli/v1/knowledge/ask", params: { question: "Cosa dice la proposta?" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(asked_scope.pluck(:id)).to eq([ pubblicata.id ])
      expect(asked_scope.pluck(:id)).not_to include(proposta.id)
    end

    it "con ?status=in_review elenca la coda di revisione" do
      proposta = create(:knowledge_page, :in_review, organization:, project:)
      pubblicata = create(:knowledge_page, organization:, project:)

      get "/cli/v1/knowledge/pages", params: { status: "in_review" }, headers: headers

      ids = response.parsed_body["data"].map { |page| page["id"] }
      expect(ids).to eq([ proposta.id ])
      expect(ids).not_to include(pubblicata.id)
    end

    it "con ?status=all le elenca tutte" do
      proposta = create(:knowledge_page, :in_review, organization:, project:)
      scartata = create(:knowledge_page, :rejected, organization:, project:)
      pubblicata = create(:knowledge_page, organization:, project:)

      get "/cli/v1/knowledge/pages", params: { status: "all" }, headers: headers

      expect(response.parsed_body["data"].map { |page| page["id"] })
        .to contain_exactly(proposta.id, scartata.id, pubblicata.id)
    end

    it "uno stato non riconosciuto è un errore, non un filtro ignorato" do
      get "/cli/v1/knowledge/pages", params: { status: "bozza" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-011")
    end

    it "con ?awaiting_consolidation elenca le accettate non ancora scritte su file" do
      da_scrivere = create(:knowledge_page, organization:, project:, reviewed_at: Time.current)
      create(:knowledge_page, organization:, project:, reviewed_at: Time.current,
                              consolidated_at: Time.current, source_path: "global/git.md")
      # Pagina scritta a mano dal web: non è mai passata da una decisione, quindi non aspetta niente.
      create(:knowledge_page, organization:, project:)

      get "/cli/v1/knowledge/pages", params: { awaiting_consolidation: 1 }, headers: headers

      expect(response.parsed_body["data"].map { |page| page["id"] }).to eq([ da_scrivere.id ])
    end

    # CYRA-768 — dal terminale si trovano le pagine oltre la data di rilettura. Confermarle no: è un
    # giudizio, e lo dà una persona dalla coda di revisione.
    it "con ?needs_review elenca solo le pagine oltre la data di rilettura" do
      scaduta = create(:knowledge_page, :decision, organization:, project:, title: "Scelta del proxy")
      scaduta.update_columns(review_after: 1.day.ago)
      futura = create(:knowledge_page, :decision, organization:, project:, title: "Ancora fresca")
      futura.update_columns(review_after: 30.days.from_now)
      create(:knowledge_page, organization:, project:, title: "Appunto")

      get "/cli/v1/knowledge/pages", params: { needs_review: 1 }, headers: headers

      expect(response.parsed_body["data"].map { |page| page["id"] }).to eq([ scaduta.id ])
    end

    it "dice per ogni pagina quando va riletta e se il termine è passato" do
      scaduta = create(:knowledge_page, :decision, organization:, project:)
      scaduta.update_columns(review_after: 1.day.ago)

      get "/cli/v1/knowledge/pages/#{scaduta.id}", headers: headers

      expect(response.parsed_body["data"]["review_after"]).to be_present
      expect(response.parsed_body["data"]["needs_review"]).to be(true)
    end

    it "una nota non ha nessuna data di rilettura e non risulta da rivedere" do
      nota = create(:knowledge_page, organization:, project:)

      get "/cli/v1/knowledge/pages/#{nota.id}", headers: headers

      expect(response.parsed_body["data"]["review_after"]).to be_nil
      expect(response.parsed_body["data"]["needs_review"]).to be(false)
    end

    it "la show di una proposta resta raggiungibile per id: chi propone rilegge la sua bozza" do
      proposta = create(:knowledge_page, :in_review, organization:, project:)

      get "/cli/v1/knowledge/pages/#{proposta.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("in_review")
    end

    it "segna una pagina accettata come scritta fra i documenti" do
      page = create(:knowledge_page, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/consolidated",
           params: { source_path: "troubleshooting/rails.md" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["source_path"]).to eq("troubleshooting/rails.md")
      expect(response.parsed_body["data"]["consolidated_at"]).to be_present
    end

    it "non consolida una pagina ancora in revisione" do
      page = create(:knowledge_page, :in_review, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/consolidated",
           params: { source_path: "global/git.md" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-009")
    end

    it "l'aggiornamento non può cambiare lo stato: la revisione non si scavalca" do
      page = create(:knowledge_page, :in_review, organization:, project:)

      patch "/cli/v1/knowledge/pages/#{page.id}",
            params: { title: "Titolo nuovo", status: "published", in_review: false }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(page.reload).to be_status_in_review
    end
  end

  # CYRA-642 — la coda di revisione si decide anche dal terminale, ma la decisione resta di una
  # persona. Il canale CLI è l'unico da cui un account di servizio può presentarsi (non fa login
  # web) e il suo token si autentica come quello di una persona: senza il guard nel service, la
  # macchina che ha proposto la pagina se la approvava da sola.
  describe "POST /cli/v1/knowledge/pages/:id/approve e /reject" do
    # L'assistente che propone: account di servizio con un token CLI, membro del progetto. È AUTORE
    # delle proposte che scrive, e l'autore di una pagina la gestisce sempre (Knowledge::PageManageable)
    # — quindi arriva davanti al service con ogni permesso in mano. Fermarlo tocca al guard umano.
    let(:machine) do
      create(:account, :service).tap { |account| create(:project_membership, account:, project:) }
    end

    let(:machine_headers) do
      secret = Accounts::ApiTokens::Issue.call(account: machine, organization:, name: "CLI").value[:secret]
      { "Authorization" => "Bearer #{secret}" }
    end

    def machine_proposal
      create(:knowledge_page, :in_review, organization:, project:, created_by: machine)
    end

    it "accetta una proposta con l'accesso personale: entra nella conoscenza" do
      page = create(:knowledge_page, :in_review, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("published")
      expect(page.reload).to be_status_published
      expect(page.reviewed_by).to eq(account)
    end

    it "l'accettazione accoda l'embedding: da qui la pagina si trova cercando" do
      page = create(:knowledge_page, :in_review, organization:, project:)

      expect { post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: headers }
        .to have_enqueued_job(::Knowledge::EmbedPageJob).with(page_id: page.id)
    end

    it "scarta una proposta con l'accesso personale: resta fuori da ricerca e liste" do
      page = create(:knowledge_page, :in_review, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/reject", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("rejected")
      expect(page.reload).to be_status_rejected
      expect(page.reviewed_by).to eq(account)
    end

    it "un account di servizio non accetta la proposta che ha scritto: 403, resta in attesa" do
      page = machine_proposal

      post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: machine_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-KNOWLEDGE-005")
      expect(page.reload).to be_status_in_review
      expect(page.reviewed_by).to be_nil
    end

    it "un account di servizio non scarta: 403 e la proposta resta in attesa" do
      page = machine_proposal

      post "/cli/v1/knowledge/pages/#{page.id}/reject", headers: machine_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-KNOWLEDGE-005")
      expect(page.reload).to be_status_in_review
    end

    it "l'account di servizio continua a proporre e a rileggere: il blocco è sulla decisione" do
      page = machine_proposal

      get "/cli/v1/knowledge/pages/#{page.id}", headers: machine_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("in_review")
    end

    it "una persona decide la proposta che l'assistente non poteva chiudere da sé" do
      page = machine_proposal

      post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: headers

      expect(response).to have_http_status(:ok)
      expect(page.reload).to be_status_published
      expect(page.reviewed_by).to eq(account)
    end

    it "si decidono soltanto le pagine in revisione: una già accettata dà 422" do
      page = create(:knowledge_page, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-009")
    end

    it "non si scarta una pagina già accettata" do
      page = create(:knowledge_page, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/reject", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-009")
    end

    it "chi non può gestire la pagina non la decide" do
      page = create(:knowledge_page, :in_review, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(page.reload).to be_status_in_review
    end

    it "accettare non consolida: restano due passaggi distinti" do
      page = create(:knowledge_page, :in_review, organization:, project:)

      post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: headers

      expect(page.reload.consolidated_at).to be_nil
      expect(::Knowledge::Page.awaiting_consolidation.pluck(:id)).to include(page.id)
    end

    it "una proposta di un progetto non visibile non si decide (anti-BOLA, 404)" do
      altro = create(:project, organization:)
      page = create(:knowledge_page, :in_review, organization:, project: altro)

      post "/cli/v1/knowledge/pages/#{page.id}/approve", headers: member_headers

      expect(response).to have_http_status(:not_found)
      expect(page.reload).to be_status_in_review
    end
  end

  # CYRA-767 — il pacchetto di contesto: l'elenco corto delle pagine di UN progetto, una riga di
  # riassunto ciascuna. È la metà che mancava al ciclo della conoscenza: si scriveva e non si
  # rileggeva. Le pagine intere restano dietro `kb show`, una per una.
  describe "GET /cli/v1/knowledge/context" do
    it "senza token → 401" do
      get "/cli/v1/knowledge/context", params: { project: project.key }

      expect(response).to have_http_status(:unauthorized)
    end

    it "elenca le pagine del progetto con titolo e riga di riassunto, dalla più recente" do
      old = create(:knowledge_page, :with_tags, organization:, project:, title: "Vecchia",
                                                body: "# Titolo\n\nCome si ripristina il database.")
      recent = create(:knowledge_page, organization:, project:, title: "Recente", body: "Il deploy passa dai tag.")
      old.update_column(:updated_at, 3.days.ago)
      recent.update_column(:updated_at, 1.hour.ago)

      get "/cli/v1/knowledge/context", params: { project: project.key.downcase }, headers: headers

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["data"]
      expect(rows.map { |row| row["id"] }).to eq([ recent.id, old.id ])
      expect(rows.first).to include("title" => "Recente", "kind" => "note", "summary" => "Il deploy passa dai tag.")
      expect(rows.last["summary"]).to eq("Come si ripristina il database.")
      expect(rows.last["tags"]).to eq(%w[flutter flutter-flavor])
      expect(response.parsed_body["meta"]).to include("project" => project.key, "limit" => 12, "total" => 2)
    end

    it "il corpo intero non viaggia nell'elenco: si apre una pagina per volta" do
      create(:knowledge_page, organization:, project:, body: "a" * 400)

      get "/cli/v1/knowledge/context", params: { project: project.key }, headers: headers

      expect(response.parsed_body["data"].first).not_to have_key("body")
      expect(response.parsed_body["data"].first["summary"].length).to eq(Knowledge::ProjectContext::SUMMARY_CHARS)
    end

    it "l'elenco ha un tetto e non cresce col numero di pagine" do
      create_list(:knowledge_page, 15, organization:, project:)

      get "/cli/v1/knowledge/context", params: { project: project.key }, headers: headers

      expect(response.parsed_body["data"].size).to eq(Knowledge::ProjectContext::DEFAULT_LIMIT)

      get "/cli/v1/knowledge/context", params: { project: project.key, limit: 3 }, headers: headers
      expect(response.parsed_body["data"].size).to eq(3)

      get "/cli/v1/knowledge/context", params: { project: project.key, limit: 999 }, headers: headers
      expect(response.parsed_body["meta"]["limit"]).to eq(Knowledge::ProjectContext::MAX_LIMIT)
      expect(response.parsed_body["data"].size).to eq(15)
    end

    it "solo le pagine accettate: le proposte in attesa restano fuori" do
      published = create(:knowledge_page, organization:, project:, title: "Accettata")
      create(:knowledge_page, :in_review, organization:, project:, title: "In attesa")

      get "/cli/v1/knowledge/context", params: { project: project.key }, headers: headers

      expect(response.parsed_body["data"].map { |row| row["id"] }).to eq([ published.id ])
    end

    it "un progetto senza pagine risponde vuoto, senza errore" do
      get "/cli/v1/knowledge/context", params: { project: project.key }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq([])
      expect(response.parsed_body["meta"]).to include("total" => 0)
    end

    it "di un progetto che non vedo non arrivano nemmeno i titoli (anti-BOLA, 404)" do
      create(:knowledge_page, organization:, project:, title: "Segreta")
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/knowledge/context", params: { project: project.key },
                                       headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-KNOWLEDGE-001")
      expect(response.body).not_to include("Segreta")
    end

    it "senza progetto non c'è contesto da dare: 422" do
      get "/cli/v1/knowledge/context", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-014")
    end
  end
end
