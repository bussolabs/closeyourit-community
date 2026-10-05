# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ComposeTicket do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Storefront") } # roadmap-on di default
  let(:client) { instance_double(Ai::Llm::Client) }

  # Con `response_schema` il modello è vincolato a produrre JSON conforme e il client lo restituisce
  # già parsato: niente involucro `choices[0].message` da spacchettare (CYRA-594).
  def draft(args)
    allow(client).to receive(:generate_content).and_return(args)
  end

  def compose(text: "il checkout va in timeout su mobile", **options)
    described_class.call(project:, text:, client:, **options)
  end

  # Il testo del turno utente e quello di sistema, come li riceve il modello.
  def prompts
    captured = {}
    allow(client).to receive(:generate_content) do |**kw|
      captured[:system] = kw[:system]
      captured[:user] = kw[:contents].first[:parts].first[:text]
      { "title" => "x", "kind" => "bug", "description" => "y" }
    end
    yield
    captured
  end

  # Le pagine che Ticketing::ComposeContext restituirebbe: quel service ha le sue prove, qui conta
  # solo cosa ComposeTicket ne fa.
  def knowledge(*pages)
    allow(Ticketing::ComposeContext).to receive(:call).and_return(pages)
  end

  describe "bozza completa" do
    it "compone un bug con titolo, tipo, scenari BDD, DoD e analisi tecnica" do
      draft(
        "title" => "Timeout al checkout su mobile", "kind" => "bug",
        "description" => "Il checkout va in timeout dopo 30s su mobile.",
        "scenarios" => [ {
          "title" => "Mobile", "step_given" => "Utente su smartphone", "step_when" => "Preme Paga",
          "step_then" => "Timeout dopo 30s", "step_expected" => "Va al pagamento"
        } ],
        "conditions" => [ "Il pagamento va a buon fine su mobile" ],
        "technical_analysis" => "timeout del gateway pagamenti a 30s"
      )

      result = compose.value
      expect(result.title).to eq("Timeout al checkout su mobile")
      expect(result.kind).to eq("bug")
      expect(result.description).to include("timeout")
      expect(result.scenarios.size).to eq(1)
      expect(result.scenarios.first[:step_given]).to eq("Utente su smartphone")
      expect(result.scenarios.first[:step_expected]).to eq("Va al pagamento")
      expect(result.conditions).to eq([ "Il pagamento va a buon fine su mobile" ])
      expect(result.technical_analysis).to eq("timeout del gateway pagamenti a 30s")
    end
  end

  describe "come viene chiamato il modello" do
    it "offre i quattro tipi standard, su qualunque progetto" do
      schema = nil
      allow(client).to receive(:generate_content) do |**kw|
        schema = kw[:response_schema]
        { "title" => "x", "kind" => "bug", "description" => "y" }
      end

      compose
      expect(schema.dig(:properties, :kind, :enum)).to eq(%w[bug story task epic])
    end

    # La bozza la legge un umano e la corregge: sul modello ridotto costa meno ma rende una traccia
    # da riscrivere da capo, che non fa risparmiare niente a nessuno.
    it "usa il modello pieno e il tetto di output largo" do
      expect(client).to receive(:generate_content)
        .with(hash_including(model: Ai::Llm::Constants::MODEL,
                             max_output_tokens: described_class::MAX_TOKENS))
        .and_return({ "title" => "x", "kind" => "bug", "description" => "y" })

      compose
    end

    it "manda il nome del progetto e la richiesta in un turno utente solo" do
      contents = nil
      allow(client).to receive(:generate_content) do |**kw|
        contents = kw[:contents]
        { "title" => "x", "kind" => "bug", "description" => "y" }
      end

      compose(text: "il checkout va in timeout")

      expect(contents.size).to eq(1)
      expect(contents.first[:role]).to eq("user")
      expect(contents.first[:parts].first[:text]).to include("Storefront", "il checkout va in timeout")
    end
  end

  # CYRA-680 — oltre al nome, il modello riceve descrizione e repository del progetto quando
  # esistono: sono le due righe che dicono di cosa parla il prodotto senza pescare in KB.
  describe "identità del progetto nel prompt" do
    it "manda la descrizione del progetto quando c'è" do
      project.update!(description: "Marketplace di ricambi auto per officine.")
      knowledge

      captured = prompts { compose }

      expect(captured[:user]).to include("Descrizione: Marketplace di ricambi auto per officine.")
    end

    it "tronca la descrizione al tetto" do
      project.update!(description: "d" * 2_000)
      knowledge

      captured = prompts { compose }

      cap = described_class::PROJECT_DESCRIPTION_CHARS
      expect(captured[:user]).not_to include("d" * (cap + 1))
      expect(captured[:user]).to include("d" * (cap - 10))
    end

    it "manda il repository GitHub con il branch di default quando è collegato" do
      create(:github_repository, project:, full_name: "bussolabs/storefront", default_branch: "main")
      knowledge

      captured = prompts { compose }

      expect(captured[:user]).to include("Repository GitHub: bussolabs/storefront (branch main)")
    end

    # La riga assente, non vuota: un'etichetta senza contenuto insegna al modello che il dato
    # esiste da qualche parte, e la reazione tipica è inventarlo.
    it "senza descrizione né repository il prompt resta quello di sempre" do
      knowledge

      captured = prompts { compose(text: "il checkout va in timeout") }

      expect(captured[:user]).to eq("Progetto: Storefront\n\nRichiesta:\nil checkout va in timeout")
    end
  end

  # CYRA-632 — fino a ieri al modello arrivava il solo nome del progetto: scriveva alla cieca, e da
  # lì i ticket generici. Ora legge al massimo due pagine di conoscenza, o nessuna.
  describe "conoscenza del progetto nel prompt" do
    let(:gateway) { create(:knowledge_page, project:, title: "Timeout del gateway", body: "La finestra è 45s.") }
    let(:retry_policy) { create(:knowledge_page, project:, title: "Ripetizione", body: "Chiave per tentativo.") }

    it "allega titolo e corpo delle pagine trovate, numerate" do
      knowledge(gateway, retry_policy)

      captured = prompts { compose }

      expect(captured[:user]).to include("Conoscenza del progetto", "[1] Timeout del gateway",
                                         "La finestra è 45s.", "[2] Ripetizione", "Chiave per tentativo.")
    end

    # Il corpo è il campo lungo: senza tetto una pagina sola può pesare quanto tutto il resto del
    # prompt, e il segnale della richiesta si annega dentro il contesto.
    it "tronca il corpo di ogni pagina al tetto" do
      long = create(:knowledge_page, project:, title: "Lunga", body: "a" * Knowledge::Constants::BODY_MAX_CHARS)
      knowledge(long)

      captured = prompts { compose }

      cap = Ticketing::ComposeContext::PAGE_BODY_CHARS
      # Il tetto include i puntini di taglio, quindi la coda è poco sotto: conta che il corpo lungo
      # non passi intero e che non sia stato ridotto a niente.
      expect(captured[:user]).not_to include("a" * (cap + 1))
      expect(captured[:user]).to include("a" * (cap - 10))
    end

    # tech_spec è gergo tecnico e pesa più del corpo: qui servono descrizione e scenari in
    # linguaggio semplice, e darglielo in pasto spinge il modello dove non deve andare.
    it "non manda la parte tecnica delle pagine" do
      technical = create(:knowledge_page, :with_tech_spec, project:, title: "Indici")
      knowledge(technical)

      captured = prompts { compose }

      expect(captured[:user]).not_to include(technical.tech_spec)
    end

    # Il prompt senza conoscenza deve restare quello di sempre: nominare un contesto che non c'è
    # insegna al modello che da qualche parte esiste, e la reazione tipica è riempirlo da sé.
    it "senza pagine pertinenti manda solo progetto e richiesta" do
      knowledge

      captured = prompts { compose(text: "il checkout va in timeout") }

      expect(captured[:user]).to eq("Progetto: Storefront\n\nRichiesta:\nil checkout va in timeout")
      expect(captured[:system]).not_to include("Conoscenza del progetto")
    end

    it "riporta nella bozza le pagine che ha letto" do
      knowledge(gateway, retry_policy)
      draft("title" => "x", "kind" => "bug", "description" => "y")

      expect(compose.value.knowledge).to eq([ { id: gateway.id, title: "Timeout del gateway" },
                                              { id: retry_policy.id, title: "Ripetizione" } ])
    end

    it "senza pagine la bozza lo dice, con una lista vuota" do
      knowledge
      draft("title" => "x", "kind" => "bug", "description" => "y")

      expect(compose.value.knowledge).to eq([])
    end
  end

  # CYRA-632 — il secondo giro: l'utente ha letto la bozza e dice cosa cambiare.
  describe "riscrittura con una correzione" do
    let(:previous) do
      { "title" => "Timeout al checkout", "kind" => "bug", "description" => "Va in timeout.",
        "scenarios" => [ { "title" => "Mobile", "step_given" => "Su telefono", "step_when" => "Pago",
                           "step_then" => "Torno al carrello", "step_expected" => "Pago davvero" } ],
        "conditions" => [ "il pagamento riesce" ], "technical_analysis" => "gateway a 30s" }
    end

    def correct(correction: "è una story, non un bug")
      compose(correction:, previous_draft: previous)
    end

    # Senza la bozza precedente per intero, «togli il secondo scenario» non ha un secondo scenario a
    # cui riferirsi e il modello ne inventa uno da togliere.
    it "rimanda la bozza precedente per intero e la correzione" do
      knowledge

      captured = prompts { correct }

      expect(captured[:user]).to include("Bozza precedente:", "titolo: Timeout al checkout", "tipo: bug",
                                         "scenario 1: Mobile — Su telefono / Pago / Torno al carrello / Pago davvero",
                                         "condizione: il pagamento riesce", "analisi tecnica: gateway a 30s",
                                         "Correzione richiesta:\nè una story, non un bug")
    end

    # L'ultimo blocco è quello a cui il modello dà più peso, ed è giusto che sia l'istruzione appena
    # scritta guardando la bozza sbagliata.
    it "mette la correzione per ultima, dopo la richiesta" do
      knowledge

      captured = prompts { correct }

      expect(captured[:user].index("Correzione richiesta:")).to be > captured[:user].index("Richiesta:")
    end

    # Senza questa regola il modello riparte dalla richiesta e cambia tutto: chi aveva chiesto una
    # cosa sola si ritrova a rileggere l'intera bozza per capire cosa è successo.
    it "chiede di riscrivere, non di ricomporre" do
      knowledge

      captured = prompts { correct }

      expect(captured[:system]).to include("RISCRIVENDO", "Non ripartire da zero")
    end

    it "senza regola di riscrittura quando non c'è correzione" do
      knowledge

      captured = prompts { compose }

      expect(captured[:system]).not_to include("RISCRIVENDO")
    end

    # Una correzione senza la bozza da correggere non è una correzione: è una seconda richiesta
    # scritta male, e il comportamento onesto è comporre da capo.
    it "compone da capo se manca la bozza precedente" do
      knowledge

      captured = prompts { compose(correction: "è una story") }

      expect(captured[:user]).not_to include("Bozza precedente:", "Correzione richiesta:")
    end

    # La correzione sposta il tema: la conoscenza utile può non essere più quella di prima.
    it "cerca la conoscenza su testo e correzione insieme" do
      allow(Ticketing::ComposeContext).to receive(:call).and_return([])
      draft("title" => "x", "kind" => "bug", "description" => "y")

      compose(text: "il checkout va in timeout", correction: "è una story", previous_draft: previous)

      expect(Ticketing::ComposeContext).to have_received(:call)
        .with(project:, query: "il checkout va in timeout\nè una story", client: nil)
    end
  end

  describe "kind fuori enum" do
    it "un kind fuori enum → fallback a bug" do
      draft("title" => "x", "kind" => "feature", "description" => "y")
      expect(compose.value.kind).to eq("bug")
    end
  end

  describe "scenari (parse + normalizzazione)" do
    it "scarta gli scenari senza alcuno step" do
      draft(
        "title" => "x", "kind" => "bug", "description" => "y",
        "scenarios" => [ { "step_given" => "valido" }, { "title" => "vuoto", "step_given" => "" } ]
      )

      expect(compose.value.scenarios.size).to eq(1)
    end

    it "gli scenari valgono anche per le feature (corpo per tutti i kind)" do
      draft(
        "title" => "x", "kind" => "story", "description" => "y",
        "scenarios" => [ { "step_given" => "sulla dashboard", "step_when" => "esporto" } ]
      )

      result = compose.value
      expect(result.kind).to eq("story")
      expect(result.scenarios.size).to eq(1)
    end
  end

  describe "fallback e input" do
    it "titolo vuoto → fallback sul testo della richiesta" do
      draft("title" => "", "kind" => "bug", "description" => "y")
      expect(compose(text: "descrizione grezza").value.title).to eq("descrizione grezza")
    end

    it "descrizione e analisi oltre i tetti → troncate (la bozza dev'essere salvabile)" do
      draft(
        "title" => "T", "kind" => "bug",
        "description" => "x" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 500),
        "technical_analysis" => "y" * (Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS + 500)
      )

      result = compose.value

      expect(result.description.length).to eq(Ticketing::Constants::DESCRIPTION_MAX_CHARS)
      expect(result.technical_analysis.length).to eq(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
    end

    it "testo vuoto → R422-TICKET-012, il client NON viene chiamato" do
      allow(client).to receive(:generate_content)
      result = compose(text: "   ")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-012")
      expect(client).not_to have_received(:generate_content)
    end
  end

  describe "esiti di errore" do
    it "description vuota dal modello → R502-AI-003 (illeggibile)" do
      draft("title" => "x", "kind" => "bug", "description" => "  ")
      expect(compose.error.code).to eq("R502-AI-003")
    end

    # CYRA-765 — senza la configurazione del server AI la bozza non si scrive, ma l'esito è un
    # errore leggibile e non un 500.
    it "server AI non configurato → non chiama il fornitore e dice cosa manca" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      result = described_class.call(project:, text: "il checkout va in timeout")

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
    end

    it "errore del fornitore → propaga codice/status/messaggio del Client::Error" do
      allow(client).to receive(:generate_content).and_raise(
        Ai::Llm::Client::Error.new("Server AI giù", code: "R502-LLM-001", status: :bad_gateway)
      )

      result = compose
      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-001")
      expect(result.error.message).to eq("Server AI giù")
    end
  end

  # CYRA-639. Con scenarios.items a proprietà tutte opzionali il decoding vincolato non obbliga mai a
  # chiudere la stringa in corso: il modello degenera, satura il budget e il JSON arriva tagliato.
  # Misurato contro l'API reale: 0/5 bozze riuscite prima, 5/5 dopo, e da ~2500 a ~400 token.
  describe "lo schema obbliga a chiudere ogni scenario" do
    it "chiede tutti e cinque i campi di uno scenario come obbligatori" do
      expect(described_class::SCHEMA.dig(:properties, :scenarios, :items, :required))
        .to eq(%w[title step_given step_when step_then step_expected])
    end

    it "dichiara al modello quanti scenari e quanto lunghi li vuole" do
      captured = prompts { compose }

      expect(captured[:system]).to include("#{described_class::MAX_SCENARIOS} scenari")
      expect(captured[:system]).to include(described_class::DESCRIPTION_HINT_CHARS.to_s)
    end
  end

  # Il taglio resta possibile: la generazione vincolata è probabilistica, e una bozza in meno è
  # un utente che riscrive tutto a mano. Un solo secondo giro, e più stretto del primo.
  describe "risposta troncata" do
    def truncated
      Ai::Llm::Client::Error.new("Il server AI ha interrotto la risposta perché troppo lunga",
                                 code: "R502-LLM-006")
    end

    def buona
      { "title" => "Amicizie e chat", "kind" => "story", "description" => "Gli utenti si aggiungono." }
    end

    it "ritenta una volta e la bozza arriva" do
      giri = 0
      allow(client).to receive(:generate_content) do |**_kw|
        giri += 1
        raise truncated if giri == 1

        buona
      end
      allow(Rails.logger).to receive(:error)

      result = compose
      expect(result).to be_ok
      expect(result.value.title).to eq("Amicizie e chat")
      expect(giri).to eq(2)
      expect(Rails.logger).to have_received(:error).with(/troncata/)
    end

    it "al secondo giro chiede al modello di stare più corto" do
      sistemi = []
      giri = 0
      allow(client).to receive(:generate_content) do |**kw|
        giri += 1
        sistemi << kw[:system]
        raise truncated if giri == 1

        buona
      end
      allow(Rails.logger).to receive(:error)

      compose
      expect(sistemi.first).not_to include(described_class::SHORTER_RULE)
      expect(sistemi.last).to include(described_class::SHORTER_RULE)
    end

    it "due giri troncati → messaggio comprensibile, nessuna eccezione, nessun terzo giro" do
      allow(client).to receive(:generate_content).and_raise(truncated)
      allow(Rails.logger).to receive(:error)

      result = compose
      expect(result).to be_err
      expect(result.error.code).to eq("R502-AI-004")
      expect(result.error.message).to eq(I18n.t("member.tickets.compose.errors.too_long"))
      expect(result.error.message).not_to include("server AI")
      expect(client).to have_received(:generate_content).twice
    end

    it "un guasto diverso non fa scattare il secondo giro" do
      allow(client).to receive(:generate_content).and_raise(
        Ai::Llm::Client::Error.new("Server AI giù", code: "R503-LLM-001", status: :service_unavailable)
      )

      expect(compose).to be_err
      expect(client).to have_received(:generate_content).once
    end
  end
end
