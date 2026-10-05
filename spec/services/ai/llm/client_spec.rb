# spec/services/ai/llm/client_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Llm::Client do
  subject(:client) { described_class.new(api_key: "test-key", base_url: "https://llm.test/v1", model: "test-model") }

  let(:url) { "https://llm.test/v1/chat/completions" }
  let(:schema) { { type: "object", properties: { ok: { type: "boolean" } }, required: [ "ok" ] } }

  # Corpo SINCRONO: lo usano solo gli attrezzi, l'unica modalità rimasta senza streaming.
  def completion(content, finish: "stop")
    { choices: [ { message: { role: "assistant", content: content }, finish_reason: finish } ],
      usage: { prompt_tokens: 1, completion_tokens: 1 } }.to_json
  end

  def sse(*events)
    events.map { |e| e == :done ? "data: [DONE]\n\n" : "data: #{e.to_json}\n\n" }.join
  end

  def chunk(text = nil, finish: nil, usage: nil, model: nil)
    payload = { "id" => "chatcmpl-1", "choices" => [ { "delta" => { "content" => text }, "finish_reason" => finish } ] }
    payload["usage"] = usage if usage
    payload["model"] = model if model
    payload
  end

  describe ".new" do
    # Credenziale unica, endpoint distinti per profilo (CYRA-841).
    around do |example|
      keys = %w[AI_API_KEY AI_BASE_URL CHAT_BASE_URL]
      original = keys.index_with { |key| ENV[key] }
      example.run
      original.each { |key, value| ENV[key] = value }
    end

    it "solleva KeyError se la chiave è vuota o nil: un Bearer vuoto è un 401 confuso a ogni richiesta" do
      expect { described_class.new(api_key: "", base_url: "https://llm.test/v1") }.to raise_error(KeyError)
      expect { described_class.new(api_key: nil, base_url: "https://llm.test/v1") }.to raise_error(KeyError)
      expect { described_class.new(api_key: "k", base_url: nil) }.to raise_error(KeyError)
    end

    it "usa una chiave comune mantenendo gli endpoint dei profili" do
      ENV["AI_API_KEY"] = "sistema"
      ENV["AI_BASE_URL"] = "https://sistema.test/v1"
      ENV["CHAT_BASE_URL"] = "https://revisore.test/v1"
      stub_request(:post, "https://sistema.test/v1/chat/completions")
        .with(headers: { "Authorization" => "Bearer sistema" }).to_return(status: 200, body: sse(chunk("a", finish: "stop"), :done))
      stub_request(:post, "https://revisore.test/v1/chat/completions")
        .with(headers: { "Authorization" => "Bearer sistema" }).to_return(status: 200, body: sse(chunk("b", finish: "stop"), :done))

      expect(described_class.new.generate_content(system: "s", contents: [])).to eq("a")
      expect(described_class.new(credentials: :knowledge_review).generate_content(system: "s", contents: [])).to eq("b")
    end

    it "il KeyError nomina la ENV del profilo che manca, non un'altra" do
      ENV["AI_API_KEY"] = nil
      ENV["CHAT_BASE_URL"] = nil

      expect { described_class.new(credentials: :knowledge_review) }.to raise_error(KeyError, /AI_API_KEY/)
    end
  end

  describe "#generate_content" do
    def call(**options)
      client.generate_content(system: "s", contents: [ { role: "user", parts: [ { text: "u" } ] } ], **options)
    end

    # Streaming SEMPRE (CYRA-766): la connessione resta viva mentre il modello scrive, e una risposta
    # lunga non incontra il 524 con cui il proxy davanti chiude a ~100 secondi.
    it "POSTa in streaming con Bearer, thinking spento, json_schema e temperatura zero" do
      post = stub_request(:post, url)
             .with(headers: { "Authorization" => "Bearer test-key" }) { |req|
               body = JSON.parse(req.body)
               body["model"] == "test-model" &&
                 body["stream"] == true &&
                 body.dig("stream_options", "include_usage") == true &&
                 body.dig("chat_template_kwargs", "enable_thinking") == false &&
                 body["temperature"] == 0.0 &&
                 body.dig("response_format", "type") == "json_schema" &&
                 body.dig("response_format", "json_schema", "strict") == true &&
                 body.dig("response_format", "json_schema", "schema", "required") == [ "ok" ] &&
                 body["messages"] == [ { "role" => "system", "content" => "s" }, { "role" => "user", "content" => "u" } ]
             }
             .to_return(status: 200, body: sse(chunk("{\"ok\":"), chunk(" true}", finish: "stop"), :done))

      expect(call(response_schema: schema)).to eq({ "ok" => true })
      expect(post).to have_been_requested
    end

    # Uno spazio è `blank?` per Rails ma non è niente: scartarlo incollerebbe fra loro le parole.
    it "tiene i delta di solo spazio: il testo non si incolla" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("ciao"), chunk(" "), chunk("mondo", finish: "stop"), :done))

      expect(call).to eq("ciao mondo")
    end

    it "senza schema restituisce il testo concatenato e non manda response_format" do
      stub_request(:post, url).with { |req| !JSON.parse(req.body).key?("response_format") }
                              .to_return(status: 200, body: sse(chunk("ciao "), chunk("mondo", finish: "stop"), :done))

      expect(call).to eq("ciao mondo")
    end

    it "ricompone un evento spezzato fra due pezzi dello stream" do
      body = sse(chunk("{\"ok\""), chunk(": false}", finish: "stop"), :done)
      stub_request(:post, url).to_return(status: 200, body: [ body[0, 20], body[20..] ].join)

      expect(call(response_schema: schema)).to eq({ "ok" => false })
    end

    it "non perde il prefisso /v1 della base URL" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("x", finish: "stop"), :done))
      call
      expect(a_request(:post, "https://llm.test/chat/completions")).not_to have_been_made
    end

    it "usa il modello passato e i tetti passati" do
      stub_request(:post, url).with(body: hash_including("model" => "altro", "max_tokens" => 99))
                              .to_return(status: 200, body: sse(chunk("x", finish: "stop"), :done))
      expect(call(model: "altro", max_output_tokens: 99)).to eq("x")
    end

    it "traduce il turno «model» in «assistant»" do
      post = stub_request(:post, url).with { |req|
        JSON.parse(req.body)["messages"].map { |m| m["role"] } == %w[system user assistant]
      }.to_return(status: 200, body: sse(chunk("x", finish: "stop"), :done))

      client.generate_content(system: "s", contents: [ { role: "user", parts: [ { text: "a" } ] },
                                                       { role: "model", parts: [ { text: "b" } ] } ])
      expect(post).to have_been_requested
    end

    it "registra il consumo dal chunk finale, con il modello che ha risposto davvero" do
      stub_request(:post, url).to_return(
        status: 200,
        body: sse(chunk("x", finish: "stop"),
                  chunk(nil, usage: { "prompt_tokens" => 12, "completion_tokens" => 3 }, model: "Qwen/Qwen3.8-27B"), :done)
      )

      call
      expect(client.usage.tokens_input).to eq(12)
      expect(client.usage.tokens_output).to eq(3)
      expect(client.usage.model).to eq("Qwen/Qwen3.8-27B")
    end

    it "con uno schema, un JSON tagliato (finish_reason length) è R502-LLM-006" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("{\"ok\":", finish: "length"), :done))

      expect { call(response_schema: schema) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq(described_class::TRUNCATED_CODE) }
    end

    it "senza schema un testo tagliato resta testo utile" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("a metà", finish: "length"), :done))

      expect(call).to eq("a metà")
    end

    it "una risposta senza testo è R502-LLM-004" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk(nil, finish: "stop"), :done))

      expect { call }.to raise_error(described_class::Error) { |e| expect(e.code).to eq(described_class::NO_TEXT_CODE) }
    end

    it "un testo che non è JSON con uno schema è R502-LLM-005, e nel log va solo la posizione" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("{non json: Mario Rossi", finish: "stop"), :done))
      allow(Rails.logger).to receive(:error)

      expect { call(response_schema: schema) }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-LLM-005") }
      expect(Rails.logger).to have_received(:error).with(satisfy { |line| !line.include?("Mario") })
    end

    {
      400 => "R502-LLM-003", 401 => "R502-LLM-002", 403 => "R502-LLM-002",
      429 => "R429-LLM-001", 503 => "R503-LLM-001", 500 => "R502-LLM-001"
    }.each do |status, code|
      it "mappa HTTP #{status} su #{code}" do
        stub_request(:post, url).to_return(status: status, body: "{}")
        expect { call }.to raise_error(described_class::Error) { |e| expect(e.code).to eq(code) }
      end
    end

    # CYRA-920
    it "tells a CloseYourIt AI key at its monthly limit apart from an outage" do
      stub_request(:post, url).to_return(status: 402, body: "{}")
      expect { call }.to raise_error(described_class::Error) { |e|
        expect(e.code).to eq("R402-LLM-001")
        expect(e.message).to eq(I18n.t("ai.limit_reached"))
      }
    end

    it "mappa il timeout su R504-LLM-001 con status gateway_timeout" do
      stub_request(:post, url).to_timeout
      expect { call }.to raise_error(described_class::Error) { |e|
        expect(e.code).to eq("R504-LLM-001")
        expect(e.status).to eq(:gateway_timeout)
      }
    end

    it "mappa reset, EOF, TLS e rete irraggiungibile su R502-LLM-001: il degrado, non un 500" do
      [ Errno::ECONNRESET, Errno::ENETUNREACH, EOFError, OpenSSL::SSL::SSLError, SocketError ].each do |klass|
        stub_request(:post, url).to_raise(klass)
        expect { call }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-LLM-001") }
      end
    end

    # Il tetto TOTALE (CYRA-764, unificato in CYRA-766): il read timeout limita l'attesa fra un pezzo
    # e l'altro, non quanto dura tutto insieme — un modello lento manda pezzi vivi e non scade mai.
    it "chiude lo stream e solleva R504-LLM-002 quando il tetto totale è superato" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("a"), chunk("b"), chunk("c", finish: "stop"), :done))
      clock = [ 0.0, 100.0 ]
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.shift || 100.0 }

      expect { call(deadline_seconds: 5) }.to raise_error(described_class::Error) { |e|
        expect(e.code).to eq("R504-LLM-002")
        expect(e.status).to eq(:gateway_timeout)
      }
    end

    # `read_timeout` è quanto si aspetta UNA lettura e riparte intero a ogni pezzo: senza accorciarlo
    # al residuo, un pezzo arrivato appena prima della scadenza comprerebbe un altro giro pieno e il
    # tetto dichiarato varrebbe quasi il doppio.
    it "accorcia l'attesa successiva al tempo che resta, invece di farla ripartire intera" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("x", finish: "stop"), :done))
      clock = [ 0.0, 3.0 ]
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.shift || 3.0 }
      timeouts = []
      allow(Net::HTTP).to receive(:new).and_wrap_original { |m, *args|
        m.call(*args).tap { |http| allow(http).to receive(:read_timeout=).and_wrap_original { |mm, v| timeouts << v; mm.call(v) } }
      }

      call(deadline_seconds: 5)
      expect(timeouts).to eq([ 5, 2.0 ])
    end

    it "con un deadline il read timeout non lo supera: uno stream fermo non aspetta i 300 s del read" do
      stub_request(:post, url).to_return(status: 200, body: sse(chunk("x", finish: "stop"), :done))
      timeouts = []
      allow(Net::HTTP).to receive(:new).and_wrap_original { |m, *args|
        m.call(*args).tap { |http| allow(http).to receive(:read_timeout=).and_wrap_original { |mm, v| timeouts << v; mm.call(v) } }
      }

      call(deadline_seconds: 5)
      expect(timeouts.first).to eq(5)
    end
  end

  describe "#stream_chat" do
    def sse_deltas(*deltas, done: true)
      frames = deltas.map { |d| "data: #{{ choices: [ { delta: { content: d } } ] }.to_json}\n\n" }
      frames << "data: [DONE]\n\n" if done
      frames.join
    end

    it "POSTa con stream: true e yielda i delta di testo in ordine" do
      post = stub_request(:post, url)
             .with(headers: { "Authorization" => "Bearer test-key" },
                   body: hash_including("stream" => true, "model" => "test-model", "temperature" => 0.2, "max_tokens" => 1024))
             .to_return(status: 200, body: sse_deltas("Ci", "ao"), headers: { "Content-Type" => "text/event-stream" })

      deltas = []
      client.stream_chat(system: "s", contents: [ { role: "user", parts: [ { text: "u" } ] } ]) { |d| deltas << d }

      expect(deltas).to eq(%w[Ci ao])
      expect(post).to have_been_requested
    end

    it "ignora keep-alive, righe vuote, [DONE], delta senza contenuto e frame illeggibili" do
      body = ": keep-alive\n\n" + sse_deltas("", nil, "ok", done: false) + "data: {non json\n\n" + "data: [DONE]\n\n"
      stub_request(:post, url).to_return(status: 200, body: body)

      deltas = []
      client.stream_chat(system: "s", contents: []) { |d| deltas << d }
      expect(deltas).to eq([ "ok" ])
    end

    it "yielda anche un delta di solo spazio: chi lo scarta incolla le parole" do
      stub_request(:post, url).to_return(status: 200, body: sse_deltas("ciao", " ", "mondo"))

      deltas = []
      client.stream_chat(system: "s", contents: []) { |d| deltas << d }
      expect(deltas.join).to eq("ciao mondo")
    end

    it "ricompone un frame spezzato su due chunk" do
      frame = "data: #{{ choices: [ { delta: { content: 'intero' } } ] }.to_json}\n\n"
      stub_request(:post, url).to_return(status: 200, body: [ frame[0, 10], frame[10..] ].join)

      deltas = []
      client.stream_chat(system: "s", contents: []) { |d| deltas << d }
      expect(deltas).to eq([ "intero" ])
    end

    it "mappa 503 su R503-LLM-001 senza ritentare su nessun altro modello" do
      stub_request(:post, url).to_return(status: 503, body: "{}")
      expect { client.stream_chat(system: "s", contents: []) { |_| } }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq(described_class::UNAVAILABLE_CODE) }
      expect(a_request(:post, url)).to have_been_made.once
    end

    it "mappa il timeout su R504-LLM-001" do
      stub_request(:post, url).to_timeout
      expect { client.stream_chat(system: "s", contents: []) { |_| } }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R504-LLM-001") }
    end
  end

  describe "#generate_with_tools" do
    let(:tools) { [ { functionDeclarations: [ { name: "list_projects", description: "Elenca", parameters: { type: "object", properties: {} } } ] } ] }

    def tool_turn(calls, content: nil)
      { choices: [ { message: { role: "assistant", content: content,
                                tool_calls: calls.map { |c| { id: c[:id], type: "function", function: { name: c[:name], arguments: c[:args].to_json } } } },
                     finish_reason: "tool_calls" } ] }.to_json
    end

    # Non-streaming di proposito: il lettore SSE tiene solo il testo, e su un turno di soli attrezzi
    # la chat resterebbe vuota per sempre senza errore.
    it "traduce functionDeclarations in tools[].function e ritorna le chiamate con id, name, args parsati" do
      post = stub_request(:post, url)
             .with(body: hash_including("tools" => [ { "type" => "function",
                                                       "function" => { "name" => "list_projects", "description" => "Elenca",
                                                                       "parameters" => { "type" => "object", "properties" => {} } } } ],
                                        "tool_choice" => "auto"))
             .to_return(status: 200, body: tool_turn([ { id: "call_1", name: "list_projects", args: { "q" => "x" } } ]))

      turn = client.generate_with_tools(system: "s", contents: [ { role: "user", parts: [ { text: "elenca" } ] } ], tools: tools)

      expect(turn.function_calls).to eq([ described_class::FunctionCall.new(id: "call_1", name: "list_projects", args: { "q" => "x" }) ])
      expect(turn.text).to eq("")
      expect(post).to have_been_requested
    end

    it "non manda stream: true — un turno di soli attrezzi non passa dal lettore SSE" do
      stub_request(:post, url).with { |req| !JSON.parse(req.body).key?("stream") }
                              .to_return(status: 200, body: completion("fatto"))

      expect(client.generate_with_tools(system: "s", contents: [], tools: tools).text).to eq("fatto")
    end

    it "ritorna il turno nel dialetto dei chiamanti, rispedibile tale e quale nel giro successivo" do
      stub_request(:post, url).to_return(status: 200, body: tool_turn([ { id: "call_1", name: "list_projects", args: {} } ], content: "cerco"))

      turn = client.generate_with_tools(system: "s", contents: [], tools: tools)

      expect(turn.content).to eq(
        "role" => "model",
        "parts" => [ { "text" => "cerco" }, { "functionCall" => { "id" => "call_1", "name" => "list_projects", "args" => {} } } ]
      )
      expect(Ai::Llm::Messages.build(system: "s", contents: [ turn.content ]).last[:tool_calls].first[:id]).to eq("call_1")
    end

    it "tollera argomenti non JSON (args vuoti) e più chiamate nello stesso turno" do
      body = { choices: [ { message: { role: "assistant", content: nil,
                                       tool_calls: [ { id: "a", type: "function", function: { name: "x", arguments: "{oops" } },
                                                     { id: "b", type: "function", function: { name: "y", arguments: "{}" } } ] } } ] }.to_json
      stub_request(:post, url).to_return(status: 200, body: body)

      turn = client.generate_with_tools(system: "s", contents: [], tools: tools)
      expect(turn.function_calls.map(&:name)).to eq(%w[x y])
      expect(turn.function_calls.first.args).to eq({})
    end

    it "un turno di solo testo, senza chiamate, è valido" do
      stub_request(:post, url).to_return(status: 200, body: completion("fatto"))
      turn = client.generate_with_tools(system: "s", contents: [], tools: tools)
      expect(turn.function_calls).to eq([])
      expect(turn.text).to eq("fatto")
    end

    it "solleva R502-LLM-004 solo quando mancano SIA testo SIA chiamate" do
      stub_request(:post, url).to_return(status: 200, body: completion(""))
      expect { client.generate_with_tools(system: "s", contents: [], tools: tools) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq(described_class::NO_TEXT_CODE) }
    end

    it "solleva R502-LLM-007 se il corpo HTTP non è JSON" do
      stub_request(:post, url).to_return(status: 200, body: "<html>")
      expect { client.generate_with_tools(system: "s", contents: [], tools: tools) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-LLM-007") }
    end
  end

  describe "#transcribe" do
    let(:transcriptions) { "https://llm.test/v1/audio/transcriptions" }
    let(:audio) { StringIO.new("RIFF....WAVEfmt ") }

    def transcribe = client.transcribe(audio: audio, filename: "voice.wav")

    it "sends the audio to the Whisper alias without a language and returns the stripped text (CYRA-908)" do
      post = stub_request(:post, transcriptions)
             .with(headers: { "Authorization" => "Bearer test-key" }) { |req|
               req.body.include?("whisper") && !req.body.include?('name="language"') &&
                 req.body.include?('filename="voice.wav"')
             }
             .to_return(status: 200, body: { text: " Apri un ticket. " }.to_json)

      expect(transcribe).to eq("Apri un ticket.")
      expect(post).to have_been_requested
    end

    it "returns an empty string when Whisper heard nothing" do
      stub_request(:post, transcriptions).to_return(status: 200, body: { text: "" }.to_json)
      expect(transcribe).to eq("")
    end

    it "maps a refused file to the same error code as a refused chat payload" do
      stub_request(:post, transcriptions).to_return(status: 400, body: "{}")
      expect { transcribe }.to raise_error(Ai::Llm::Client::Error) { |e| expect(e.code).to eq("R502-LLM-003") }
    end

    it "maps a network failure to the transport error" do
      stub_request(:post, transcriptions).to_raise(Errno::ECONNREFUSED)
      expect { transcribe }.to raise_error(Ai::Llm::Client::Error) { |e| expect(e.code).to eq("R502-LLM-001") }
    end

    it "maps an unreadable body to the unreadable-response error" do
      stub_request(:post, transcriptions).to_return(status: 200, body: "not json")
      expect { transcribe }.to raise_error(Ai::Llm::Client::Error) { |e| expect(e.code).to eq("R502-LLM-007") }
    end
  end
end
