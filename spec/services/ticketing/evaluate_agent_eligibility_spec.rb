# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::EvaluateAgentEligibility do
  subject(:result) { described_class.call(ticket:, client:) }

  let(:ticket) { create(:ticket, description: "Il bottone di logout non risponde al primo clic") }
  let(:client) { instance_double(Ai::Llm::Client) }
  # Un motore solo dal CYRA-594: con response_schema il verdetto torna come Hash gia parsato.
  def stub_verdict(eligibility: "allowed", reason: "Bugfix di interfaccia circoscritto.", risks: [ "none" ])
    allow(client).to receive(:generate_content)
      .and_return({ "eligibility" => eligibility, "reason" => reason, "risks" => risks })
  end

  alias_method :stub_vision_verdict, :stub_verdict

  # identify: false = il content_type dichiarato è quello che conta. Serve per i casi in cui il tipo
  # è il soggetto del test (es. image/gif): ActiveStorage altrimenti ri-sniffa i byte della fixture e
  # lo correggerebbe, mascherando la regola che stiamo verificando.
  def attach(ticket, fixture:, filename:, content_type:)
    ticket.files.attach(io: File.open(Rails.root.join("spec/fixtures/files/#{fixture}")),
                        filename: filename, content_type: content_type, identify: false)
    ticket.reload
  end

  describe "verdetto" do
    it "restituisce consentito con motivazione e rischi per un lavoro ordinario" do
      stub_verdict

      expect(result).to be_ok
      expect(result.value).to have_attributes(eligibility: "allowed",
                                              reason: "Bugfix di interfaccia circoscritto.",
                                              risks: [ "none" ])
    end

    it "restituisce bloccato per un ticket distruttivo" do
      stub_verdict(eligibility: "blocked", reason: "Chiede di svuotare il database di produzione.",
                   risks: %w[destructive_production irreversible_data_migration])

      expect(result.value.eligibility).to eq("blocked")
      expect(result.value.risks).to eq(%w[destructive_production irreversible_data_migration])
    end

    it "scarta le categorie di rischio fuori dall'enum" do
      stub_verdict(risks: %w[destructive_production categoria_inventata])

      expect(result.value.risks).to eq(%w[destructive_production])
    end

    it "ripiega su none quando il modello non elenca rischi validi" do
      stub_verdict(risks: [])

      expect(result.value.risks).to eq(%w[none])
    end
  end

  # Il client se lo costruisce da se, senza chiedere niente all'organizzazione (CYRA-765), e il
  # tetto di output e quello del vaglio: un verdetto troncato a meta non e un verdetto.
  it "costruisce il client del server AI e gli passa il tetto di output del vaglio" do
    allow(Ai::Llm::Client).to receive(:new).and_return(client)
    stub_verdict

    described_class.call(ticket:)

    expect(Ai::Llm::Client).to have_received(:new).with(no_args)
    expect(client).to have_received(:generate_content)
      .with(hash_including(max_output_tokens: Ticketing::Constants::AGENT_ELIGIBILITY_MAX_TOKENS))
  end

  describe "prompt" do
    it "manda titolo, corpo e schema del verdetto" do
      stub_verdict

      result

      expect(client).to have_received(:generate_content) do |args|
        expect(args[:system]).to include("gate di sicurezza", "Nel dubbio, blocca")
        expect(args[:response_schema][:required]).to eq(%w[eligibility reason risks])
        text = args[:contents].first[:parts].first[:text]
        expect(text).to include(ticket.project.key, "Il bottone di logout non risponde al primo clic")
      end
    end

    it "include le condizioni di completamento, dove può nascondersi l'istruzione pericolosa" do
      create(:ticketing_condition, ticket: ticket, text: "La tabella di produzione è stata svuotata")
      stub_verdict

      described_class.call(ticket: ticket.reload, client:)

      expect(client).to have_received(:generate_content) do |args|
        expect(args[:contents].first[:parts].first[:text]).to include("La tabella di produzione è stata svuotata")
      end
    end
  end

  # CYRA-191: il gate bloccava ticket risolvibili nel codice solo perché NOMINAVANO un dettaglio
  # d'infrastruttura, e scambiava un dato oscurato dallo scrub PII per un dato presente. Il prompt
  # ora dichiara il perimetro reale dell'agente e distingue l'operare dal nominare. I test guardano
  # il testo del prompt normalizzato agli spazi, così restano validi anche se cambia il wrapping.
  describe "perimetro dichiarato all'agente (CYRA-191)" do
    let(:prompt) { described_class::SYSTEM_PROMPT.tr("\n", " ").squeeze(" ") }

    it "dichiara che l'agente opera solo su sviluppo, test e staging e mai in produzione" do
      expect(prompt).to include("Opera SOLO su ambienti di sviluppo, test e staging")
      expect(prompt).to include("NON tocca MAI la produzione")
    end

    it "dichiara che l'agente non possiede i segreti dell'infrastruttura, senza promettere che non li legga" do
      expect(prompt).to include("NON possiede i segreti dell'infrastruttura")
      expect(prompt).to include("chiavi API, token, password")
      # Il vecchio wording "non può ottenere / non è in grado di leggerlo" avrebbe fatto approvare
      # l'esposizione di un segreto reale già presente nel testo: non deve più esserci.
      expect(prompt).not_to include("non può ottenere")
    end

    it "distingue l'operare sull'infrastruttura dal nominarla" do
      expect(prompt).to include("Decidi in base al LAVORO che il ticket richiede, non alle parole")
      expect(prompt).to include("NON è di per sé un motivo di blocco")
    end

    it "spiega che un valore oscurato è un segreto rimosso, non un segreto presente" do
      expect(prompt).to match(/valore oscurato.+RIMOSSO/i)
      expect(prompt).to include("segnalazioni automatiche di errore")
    end

    # Il fix non deve trasformarsi in un lasciapassare: un segreto reale IN CHIARO (es. copiato nel
    # titolo grezzo di un errore promosso, che non passa dallo scrub per chiave) resta un rischio.
    it "considera un rischio un segreto reale esposto in chiaro, non solo nominato" do
      expect(prompt).to include("in chiaro (non oscurato)")
      expect(prompt).to include("un segreto rimasto in chiaro resta un rischio")
    end

    it "restringe deploy_infrastructure alla produzione" do
      expect(prompt).to include("deploy manuali o rilasci IN PRODUZIONE")
    end
  end

  describe "allegati" do
    # Un motore solo (CYRA-594): le immagini sono parti in più dello stesso turno, non un'altra strada.
    def image_parts(args) = args[:contents].dig(0, :parts).select { |part| part.key?(:inline_data) }
    def prompt_text(args) = args[:contents].dig(0, :parts, 0, :text)

    it "manda le immagini come inline_data, insieme al testo" do
      attach(ticket, fixture: "screenshot.png", filename: "console.png", content_type: "image/png")
      stub_verdict(eligibility: "blocked", reason: "Lo screenshot mostra un TRUNCATE in produzione.",
                   risks: %w[destructive_production])

      outcome = described_class.call(ticket: ticket.reload, client:)

      expect(outcome.value.eligibility).to eq("blocked")
      expect(client).to have_received(:generate_content) do |args|
        image = image_parts(args).first
        expect(image.dig(:inline_data, :mime_type)).to eq("image/png")
        expect(image.dig(:inline_data, :data)).to be_present
        expect(prompt_text(args)).to include("Allegati analizzati: console.png")
        expect(args[:response_schema][:required]).to eq(%w[eligibility reason risks])
      end
    end

    # CYRA-765 — il client nasce da ENV, con o senza immagini: niente credenziale per organizzazione.
    it "usa il client del server AI anche quando il ticket porta immagini" do
      attach(ticket, fixture: "screenshot.png", filename: "console.png", content_type: "image/png")
      stub_verdict
      allow(Ai::Llm::Client).to receive(:new).and_return(client)

      described_class.call(ticket: ticket.reload)

      expect(Ai::Llm::Client).to have_received(:new).with(no_args)
    end

    it "un ticket senza immagini viaggia col solo testo" do
      stub_verdict

      result

      expect(client).to have_received(:generate_content) { |args| expect(image_parts(args)).to be_empty }
    end

    # Valutare alla cieca un ticket il cui unico segnale di rischio sta nell'immagine darebbe un
    # verdetto costruito su ciò che il modello NON ha visto: meglio nessun verdetto.
    it "fallisce chiuso quando la quota è esaurita, invece di valutare senza aver visto" do
      attach(ticket, fixture: "screenshot.png", filename: "console.png", content_type: "image/png")
      allow(client).to receive(:generate_content)
        .and_raise(Ai::Llm::Client::Error.new("quota", code: "R429-LLM-001", status: :too_many_requests))

      outcome = described_class.call(ticket: ticket.reload, client:)

      expect(outcome).to be_err
      expect(outcome.error.code).to eq("R429-LLM-001")
    end

    it "inlinea gli allegati testuali nel prompt invece che come binario" do
      attach(ticket, fixture: "notes.txt", filename: "note.txt", content_type: "text/plain")
      stub_verdict

      result

      expect(client).to have_received(:generate_content) do |args|
        expect(image_parts(args)).to be_empty
        expect(prompt_text(args)).to include("Contenuto degli allegati testuali:", "note.txt")
      end
    end

    it "legge i byte UTF-8 degli allegati e tronca per caratteri, non per byte" do
      ticket.update!(description: "La funzionalità non è disponibile")
      text = "È già disponibile: perché no? 🎉 " * 200
      ticket.files.attach(io: StringIO.new(text.b), filename: "note.txt", content_type: "text/plain")
      stub_verdict

      expect(result).to be_ok

      expect(client).to have_received(:generate_content) do |args|
        prompt = prompt_text(args)
        expect(prompt.encoding).to eq(Encoding::UTF_8)
        expect(prompt).to be_valid_encoding
        expect(prompt).to include(text.truncate(Ticketing::Constants::AGENT_ELIGIBILITY_MAX_INLINE_TEXT_CHARS))
      end
    end

    it "non chiede un verdetto su un allegato testuale con byte UTF-8 invalidi" do
      ticket.files.attach(io: StringIO.new("testo \xFF".b), filename: "note.txt",
                          content_type: "text/plain", identify: false)
      stub_verdict

      expect(result).to be_err
      expect(result.error.code).to eq("R422-AI-007")
      expect(client).not_to have_received(:generate_content)
    end

    # image/gif è ammesso come allegato ma NON è tra i formati che il modello sa leggere: spedirlo
    # sarebbe un errore, non una degradazione.
    it "non spedisce i tipi che il modello non supporta e li dichiara come non analizzati" do
      attach(ticket, fixture: "screenshot.png", filename: "animazione.gif", content_type: "image/gif")
      stub_verdict

      result

      expect(client).to have_received(:generate_content) do |args|
        expect(image_parts(args)).to be_empty
        expect(prompt_text(args)).to include("Allegati NON analizzati", "animazione.gif")
      end
    end

    it "si ferma al tetto sul numero di allegati e dichiara gli esclusi" do
      stub_const("Ticketing::Constants::AGENT_ELIGIBILITY_MAX_INLINE_ATTACHMENTS", 1)
      attach(ticket, fixture: "screenshot.png", filename: "primo.png", content_type: "image/png")
      attach(ticket, fixture: "screenshot.png", filename: "secondo.png", content_type: "image/png")
      stub_verdict

      described_class.call(ticket: ticket.reload, client:)

      expect(client).to have_received(:generate_content) do |args|
        expect(image_parts(args).size).to eq(1)
        expect(prompt_text(args)).to include("Allegati analizzati: primo.png")
        expect(prompt_text(args)).to include("Allegati NON analizzati", "secondo.png")
      end
    end

    it "si ferma al tetto sui byte grezzi e manda il solo testo" do
      stub_const("Ticketing::Constants::AGENT_ELIGIBILITY_MAX_INLINE_BYTES", 10)
      attach(ticket, fixture: "screenshot.png", filename: "grande.png", content_type: "image/png")
      stub_verdict

      result

      expect(client).to have_received(:generate_content) do |args|
        expect(image_parts(args)).to be_empty
        expect(prompt_text(args)).to include("Allegati NON analizzati", "grande.png")
      end
    end
  end

  # Il fail-closed non è una scrittura difensiva: è che in nessuno di questi rami il service
  # restituisce un verdetto, quindi il chiamante non scrive nulla e il ticket resta pending.
  describe "fail-closed" do
    def expect_failure(code)
      expect(result).to be_err
      expect(result.error.code).to eq(code)
      expect(result.value).to be_nil
    end

    it "fallisce chiuso su errore del client del server AI, conservandone il codice" do
      allow(client).to receive(:generate_content)
        .and_raise(Ai::Llm::Client::Error.new("giù", code: "R502-LLM-001", status: :bad_gateway))

      expect_failure("R502-LLM-001")
    end

    # CYRA-765 — IL PUNTO DELICATO: senza il server AI configurato NON si analizza, quindi il ticket
    # non riceve verdetto e resta `pending`, cioè fuori dalla coda degli agenti. Nessun verdetto
    # inventato, in nessun ramo — vale anche con gli allegati da leggere.
    it "col server AI non configurato non produce nessun verdetto, nemmeno con un'immagine allegata" do
      attach(ticket, fixture: "screenshot.png", filename: "schermata.png", content_type: "image/png")
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      esito = described_class.call(ticket: ticket.reload)

      expect(esito).to be_err
      expect(esito.error.code).to eq("R502-LLM-002")
      expect(esito.value).to be_nil
      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "fallisce chiuso su risposta non parsabile" do
      allow(client).to receive(:generate_content).and_raise(JSON::ParserError)

      expect_failure("R502-AI-003")
    end

    it "fallisce chiuso su un verdetto fuori dall'enum" do
      stub_verdict(eligibility: "forse")

      expect_failure("R502-AI-003")
    end

    # "pending" non è un verdetto: è l'assenza di un verdetto, e non deve poter essere scritto dall'AI.
    it "fallisce chiuso se il modello prova a rispondere pending" do
      stub_verdict(eligibility: "pending")

      expect_failure("R502-AI-003")
    end

    it "fallisce chiuso su una motivazione vuota" do
      stub_verdict(reason: "   ")

      expect_failure("R502-AI-003")
    end

    it "non restituisce MAI allowed in un ramo di errore" do
      [ Ai::Llm::Client::Error.new("x", code: "R502-LLM-001"), JSON::ParserError, TypeError ]
        .each do |failure|
          allow(client).to receive(:generate_content).and_raise(failure)

          outcome = described_class.call(ticket:, client:)

          expect(outcome).to be_err
          expect(outcome.value).to be_nil
        end
    end
  end

  # Freno d'emergenza del god (Ai::Feature). Nato dall'incidente del 2026-07-29: un backfill saturò
  # il rate limit del provider e l'unico modo di fermarlo sarebbe stato un rilascio.
  describe "interruttore del god" do
    before { Settings::Global.instance.update!(ai_agent_gate_enabled: false) }

    it "non spende una chiamata al provider" do
      expect(client).not_to receive(:generate_content)

      expect(result).to be_err
    end

    it "risponde col codice del servizio spento" do
      expect(result.error.code).to eq("R503-AI-001")
      expect(result.error.status).to eq(:service_unavailable)
    end

    # Il ticket resta `pending` = già fuori dalla coda degli agenti: spegnere il gate è fail-closed,
    # esattamente come esaurire i tentativi. Nessun verdetto inventato per difetto.
    it "non scrive alcun verdetto sul ticket" do
      result

      expect(ticket.reload.agent_eligibility).to eq("pending")
    end

    it "torna a valutare appena il god riaccende" do
      Settings::Global.instance.update!(ai_agent_gate_enabled: true)
      stub_verdict

      expect(described_class.call(ticket:, client:)).to be_ok
    end
  end
end
