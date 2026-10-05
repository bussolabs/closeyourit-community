# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Converse do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: organization, key: "CYRA", name: "closeyourit-rails") }
  let(:context) do
    Assistant::Tools::Context.new(account: account, organization: organization,
                                  project_ids: [ project.id ], group_ids: [], full_access: false)
  end
  # Stub di default: i test che verificano "non ha chiamato il modello" hanno comunque bisogno che il
  # metodo sia stubbato per poterlo interrogare.
  let(:client) { instance_double(Ai::Llm::Client, generate_with_tools: turn(text: "ok")) }

  # Un turno del modello come lo restituisce il client: `content` è l'hash grezzo, firma compresa.
  def turn(text: "", calls: [])
    parts = calls.map { |c| { "functionCall" => { "id" => c.id, "name" => c.name, "args" => c.args },
                              "thoughtSignature" => "firma" } }
    parts << { "text" => text } if text.present?
    Ai::Llm::Client::Turn.new(content: { "role" => "model", "parts" => parts },
                                 function_calls: calls, text: text)
  end

  def call_for(name, id: "call_1", args: {})
    Ai::Llm::Client::FunctionCall.new(id: id, name: name, args: args)
  end

  def converse(question: "come va?", history: [])
    described_class.call(context: context, question: question, history: history, client: client)
  end

  # CYRA-812 — se fra la domanda e la risposta è stato tolto l'accesso a qualcosa, chi ha chiesto
  # deve saperlo: una risposta più povera consegnata in silenzio si legge come un dato di fatto.
  describe "quando il perimetro si è ristretto dopo la domanda" do
    let(:context) do
      Assistant::Tools::Context.new(account: account, organization: organization,
                                    project_ids: [], group_ids: [], full_access: false,
                                    scope_reduced: true)
    end

    it "dice al modello di spiegare che il perimetro è cambiato" do
      converse

      expect(client).to have_received(:generate_with_tools).with(
        hash_including(system: a_string_including(Assistant::Tools::SystemPrompt::SCOPE_REDUCED_RULE.strip))
      )
    end
  end

  it "non parla di perimetro cambiato quando non è cambiato niente" do
    converse

    expect(client).to have_received(:generate_with_tools) do |args|
      expect(args[:system]).not_to include(Assistant::Tools::SystemPrompt::SCOPE_REDUCED_RULE.strip)
    end
  end

  describe "quando il modello risponde senza usare attrezzi" do
    it "restituisce il testo così com'è" do
      allow(client).to receive(:generate_with_tools).and_return(turn(text: "Tutto tranquillo."))

      result = converse

      expect(result).to be_ok
      expect(result.value.text).to eq("Tutto tranquillo.")
      expect(result.value.tools_used).to be_empty
    end

    it "manda al modello la domanda in coda alla storia della conversazione" do
      storia = [ { role: "user", parts: [ { text: "ciao" } ] },
                 { role: "model", parts: [ { text: "dimmi" } ] } ]
      allow(client).to receive(:generate_with_tools).and_return(turn(text: "eccomi"))

      converse(question: "e adesso?", history: storia)

      expect(client).to have_received(:generate_with_tools) do |**args|
        expect(args[:contents].size).to eq(3)
        expect(args[:contents].last).to eq(role: "user", parts: [ { text: "e adesso?" } ])
      end
    end
  end

  describe "quando il modello chiede un attrezzo" do
    it "lo esegue, rimanda il risultato e restituisce la risposta finale" do
      allow(client).to receive(:generate_with_tools)
        .and_return(turn(calls: [ call_for("list_projects") ]), turn(text: "Hai un progetto: CYRA."))

      result = converse(question: "che progetti ho?")

      expect(result.value.text).to eq("Hai un progetto: CYRA.")
      expect(result.value.tools_used).to eq([ "list_projects" ])
    end

    # VINCOLO verificato sull'API reale: senza la firma il giro successivo è un 400.
    it "rimanda il turno del modello integrale, firma di pensiero compresa" do
      allow(client).to receive(:generate_with_tools)
        .and_return(turn(calls: [ call_for("list_projects") ]), turn(text: "fatto"))

      converse

      expect(client).to have_received(:generate_with_tools).twice do |**args|
        next if args[:contents].size == 1 # primo giro: solo la domanda

        model_turn = args[:contents].find { |c| c["role"] == "model" }
        expect(model_turn["parts"].first["thoughtSignature"]).to eq("firma")
      end
    end

    # VINCOLO verificato: rispondendo a meno chiamate di quante ne arrivano, l'API torna testo vuoto
    # senza errore. Una risposta per OGNI chiamata, con lo stesso id.
    it "produce una risposta per ogni chiamata dello stesso turno" do
      calls = [ call_for("project_health", id: "call_1", args: { "project" => "CYRA" }),
                call_for("list_projects", id: "call_2") ]
      allow(client).to receive(:generate_with_tools).and_return(turn(calls: calls), turn(text: "ecco"))

      converse

      expect(client).to have_received(:generate_with_tools).twice do |**args|
        next if args[:contents].size == 1

        responses = args[:contents].last[:parts]
        expect(responses.map { |p| p[:functionResponse][:id] }).to eq(%w[call_1 call_2])
        expect(responses.map { |p| p[:functionResponse][:name] }).to eq(%w[project_health list_projects])
      end
    end

    it "elenca gli attrezzi usati, in ordine, anche quando la catena è lunga" do
      allow(client).to receive(:generate_with_tools)
        .and_return(turn(calls: [ call_for("list_projects") ]),
                    turn(calls: [ call_for("project_health", args: { "project" => "CYRA" }) ]),
                    turn(text: "CYRA sta bene."))

      expect(converse.value.tools_used).to eq(%w[list_projects project_health])
    end
  end

  describe "guardrail" do
    it "si ferma al tetto dei giri invece di ciclare all'infinito" do
      allow(client).to receive(:generate_with_tools).and_return(turn(calls: [ call_for("list_projects") ]))

      result = converse

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ASSISTANT-002")
      expect(client).to have_received(:generate_with_tools).exactly(described_class::MAX_TURNS).times
    end

    # Il tetto sui giri non basta da solo: cinque giri di attrezzi che rispondono molto gonfiano il
    # prompt (e il conto) senza che il numero di giri lo dica. Qui si ferma prima di spendere.
    it "si ferma quando il contesto accumulato supera il tetto, senza chiedere un altro giro" do
      stub_const("#{described_class}::MAX_CONTEXT_CHARS", 200)
      allow(client).to receive(:generate_with_tools)
        .and_return(turn(calls: [ call_for("get_ticket", args: { "code" => "CYRA-1" }) ]), turn(text: "tardi"))

      result = converse(question: "a" * 300)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ASSISTANT-003")
      expect(client).not_to have_received(:generate_with_tools)
    end

    it "prosegue la conversazione quando un attrezzo non trova nulla" do
      allow(client).to receive(:generate_with_tools)
        .and_return(turn(calls: [ call_for("project_health", args: { "project" => "INESISTENTE" }) ]),
                    turn(text: "Non trovo quel progetto."))

      expect(converse).to be_ok
    end

    it "non chiama il modello quando la funzione è spenta dal pannello" do
      allow(Ai::Feature).to receive(:disabled?).with(:assistant_tools).and_return(true)

      result = converse

      expect(result.error.code).to eq("R503-AI-001")
      expect(client).not_to have_received(:generate_with_tools)
    end

    it "rifiuta una domanda vuota senza spendere una chiamata" do
      result = converse(question: "   ")

      expect(result.error.code).to eq("R422-ASSISTANT-001")
      expect(client).not_to have_received(:generate_with_tools)
    end

    it "riporta l'errore del provider invece di rispondere a vuoto" do
      allow(client).to receive(:generate_with_tools)
        .and_raise(Ai::Llm::Client::Error.new("Server AI: timeout", code: "R504-LLM-001",
                                              status: :gateway_timeout))

      result = converse

      expect(result).to be_err
      expect(result.error.code).to eq("R504-LLM-001")
    end

    # Il server AI senza chiave o indirizzo solleva KeyError prima della rete: è una configurazione
    # mancante e va detta come tale, non lasciata salire come errore di sistema (CYRA-765).
    it "col server AI non configurato non chiama il modello e dice che manca la configurazione" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError.new("AI_API_KEY vuota"))

      result = described_class.call(context: context, question: "come va?")

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
    end

    # L'AI la offre il sistema (CYRA-765): il client nasce dalla configurazione di ambiente, non da
    # una credenziale dell'organizzazione.
    it "senza un client passato lo costruisce dalla configurazione di sistema" do
      allow(Ai::Llm::Client).to receive(:new).and_return(client)

      described_class.call(context: context, question: "come va?")

      expect(Ai::Llm::Client).to have_received(:new).with(no_args)
    end

    # La ricerca semantica giù non ferma la conversazione: l'attrezzo torna con l'errore dentro, il
    # modello lo legge e lo dice a chi ha chiesto. Il guasto arriva a chi legge, non resta muto.
    it "porta al modello l'errore della ricerca semantica invece di far cadere tutto" do
      allow(Ticketing::AskTickets).to receive(:call)
        .and_return(Result.err(AppError.new("Servizio embedding non raggiungibile", code: "R502-EMBED-001")))
      allow(client).to receive(:generate_with_tools)
        .and_return(turn(calls: [ call_for("ask_tickets", args: { "question" => "login?" }) ]),
                    turn(text: "La ricerca non è disponibile in questo momento."))

      result = converse

      expect(result).to be_ok
      expect(client).to have_received(:generate_with_tools).twice do |**args|
        next if args[:contents].size == 1

        risposta = args[:contents].last[:parts].first[:functionResponse][:response]
        expect(risposta[:error]).to include("embedding")
      end
    end
  end

  describe "with a page catalog" do
    let(:function) do
      Assistant::BuildCatalog::Function.new(key: "tickets", label: "Ticket",
                                            description: "Board of the tickets", path: "/member/tickets")
    end

    it "sends the catalog in the system prompt" do
      described_class.call(context: context, question: "where are my tickets?", client: client,
                           catalog: [ function ])

      expect(client).to have_received(:generate_with_tools)
        .with(hash_including(system: a_string_including("(path: /member/tickets)")))
    end
  end
end
