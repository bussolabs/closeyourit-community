# app/services/ai/llm/client.rb
# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

module Ai
  module Llm
    # UNICO client verso il proxy LiteLLM (OpenAI-compatible) davanti a vLLM sul server AI di casa.
    #
    # Fino al CYRA-766 ce n'erano due sullo STESSO proxy e sullo STESSO alias: questo (CYRA-765,
    # `AI_*`, per assistente, smistamento, bozze, doppioni e RAG) e `Ai::Chat::Client` (CYRA-764,
    # `CHAT_*`, per il solo revisore knowledge). Due letture SSE, due mappe di codici d'errore, due
    # serie di timeout da tenere allineate a mano — e già divergevano: il tetto di attesa TOTALE
    # esisteva solo di là, il JSON guidato e gli attrezzi solo di qua. Qui c'è tutto una volta sola.
    #
    # Tre chiamate: `stream_chat` (SSE, delta al blocco), `generate_content` (testo intero, con
    # schema → Hash) e `generate_with_tools` (function calling). I chiamanti passano `contents` nel
    # dialetto ereditato (`role: user|model`, `parts`): lo traduce Ai::Llm::Messages.
    #
    # Una AI_API_KEY per ambiente; il profilo sceglie solo l'endpoint (CYRA-841).
    # I path si appendono alla base /v1 senza scartare il prefisso.
    class Client
      class Error < StandardError
        attr_reader :code, :status

        def initialize(message, code:, status: :bad_gateway)
          super(message)
          @code = code
          @status = status
        end
      end

      # Il fornitore non risponde (503): i chiamanti degradano, nessuna riserva su un secondo modello.
      UNAVAILABLE_CODE = "R503-LLM-001"
      # Risposta non arrivata in fondo (`finish_reason: "length"`): chi vuole ritentare più stretto
      # (Ticketing::ComposeTicket) legge questo, la stringa sta in un posto solo.
      TRUNCATED_CODE = "R502-LLM-006"
      # Nessun testo: il modello non ha detto niente (filtro, o solo tool_calls dove non attesi).
      NO_TEXT_CODE = "R502-LLM-004"

      Profile = Data.define(:api_key_env, :base_url_env)

      # Una credenziale condivisa; endpoint configurabili per funzione (CYRA-841).
      # Gli interruttori delle funzioni restano indipendenti dalla credenziale.
      CREDENTIALS = {
        system: Profile.new(api_key_env: "AI_API_KEY", base_url_env: "AI_BASE_URL"),
        knowledge_review: Profile.new(api_key_env: "AI_API_KEY", base_url_env: "CHAT_BASE_URL")
      }.freeze

      def self.vllm_extras? = Ai::Configuration.current.provider != "custom"

      def self.base_url_for(credentials)
        CREDENTIALS.fetch(credentials)
        config = Ai::Configuration.current
        credentials == :knowledge_review ? config.review_base_url : config.chat_base_url
      end

      Usage = Data.define(:tokens_input, :tokens_output, :model, :request_id)
      FunctionCall = Data.define(:id, :name, :args)
      # `content` è il turno del modello nel DIALETTO dei chiamanti: Assistant::Converse lo rimette in
      # `contents` così com'è nel giro dopo, e Messages lo ritraduce in `assistant` + `tool_calls`.
      # Il wire OpenAI vuole un messaggio `tool` per OGNI `tool_call_id`: rispondere a meno chiamate
      # NON è un errore per il server (verificato: 200), il modello ripete la chiamata rimasta e la
      # conversazione gira a vuoto — quindi `function_calls` è sempre una lista, da servire intera.
      Turn = Data.define(:content, :function_calls, :text)

      # Consumo dell'ULTIMA chiamata (`stream_options: include_usage`). Il modello registrato è quello
      # che ha risposto davvero, non l'alias chiesto: dietro un alias può esserci una versione diversa,
      # e il verdetto è di quella versione.
      attr_reader :usage

      # Defaults come from Ai::Configuration (environment, CloseYourIt key or custom provider,
      # CYRA-916); `credentials` picks the address. Explicit values still win, and an empty string
      # passed by hand is a configuration error, never a fallback.
      def initialize(credentials: :system,
                     api_key: Ai::Configuration.current.api_key,
                     base_url: self.class.base_url_for(credentials),
                     model: Ai::Configuration.current.chat_model,
                     max_output_tokens: Ai::Llm::Constants::MAX_OUTPUT_TOKENS,
                     temperature: Ai::Llm::Constants::TEMPERATURE)
        profile = CREDENTIALS.fetch(credentials)
        # Vuota o assente → KeyError PRIMA della POST: un Bearer vuoto è un 401 confuso a ogni
        # richiesta. I service la intercettano come «servizio non configurato», mai un 500.
        raise KeyError, "#{profile.api_key_env} vuota" if api_key.blank?
        raise KeyError, "#{profile.base_url_env} vuota" if base_url.blank?

        @api_key = api_key
        @base_url = base_url.to_s.chomp("/")
        @model = model
        @max_output_tokens = max_output_tokens
        @temperature = temperature
        @usage = Usage.new(tokens_input: 0, tokens_output: 0, model: model, request_id: nil)
      end

      # Streamma una risposta multi-turno (SSE). Yielda ogni delta di testo al blocco: il chiamante
      # (Assistant::StreamReplyJob) li inoltra al browser via Turbo. Nessuna riserva su un secondo
      # modello: un 503 è «server AI giù» e propaga.
      def stream_chat(system:, contents:)
        post_stream(stream_body(system, contents, nil, @model, @max_output_tokens, @temperature), nil) { |delta| yield delta }
        nil
      end

      # Chiamata sincrona per chi la chiama, in streaming sul wire: la connessione resta viva mentre
      # il modello scrive, e una risposta lunga non incontra il 524 con cui il proxy davanti chiude a
      # ~100 secondi. `deadline_seconds` è il tetto TOTALE: il read timeout limita l'attesa fra un
      # pezzo e l'altro, non quanto dura tutto insieme, e un modello lento manda pezzi vivi ma pochi.
      # Con `response_schema` (JSON Schema) l'output è vincolato e torna già parsato; senza, è testo.
      def generate_content(system:, contents:, response_schema: nil, model: nil,
                           max_output_tokens: Ai::Llm::Constants::STRUCTURED_MAX_OUTPUT_TOKENS,
                           temperature: Ai::Llm::Constants::STRUCTURED_TEMPERATURE, deadline_seconds: nil)
        text = +""
        finish_reason = post_stream(stream_body(system, contents, response_schema, model || @model,
                                                max_output_tokens, temperature), deadline_seconds) { |delta| text << delta }

        # Il troncamento si giudica PRIMA del testo vuoto: con uno schema un JSON tagliato non si
        # parsa, e quando per caso si parsa è un verdetto parziale, peggio di un errore (CYRA-639).
        raise truncated_error if finish_reason == "length" && (text.empty? || response_schema)
        raise empty_error(finish_reason) if text.empty?
        return text unless response_schema

        parse_model_json(text)
      end

      # Chiamata sincrona CON attrezzi (function calling), per l'assistente che legge i dati.
      # Non-streaming di proposito: il lettore SSE tiene solo il testo, e su un turno di soli
      # attrezzi la chat resterebbe vuota per sempre senza errore.
      def generate_with_tools(system:, contents:, tools:,
                              max_output_tokens: @max_output_tokens, temperature: @temperature)
        payload = post_json(base_body(system, contents, @model, max_output_tokens, temperature)
                              .merge(tools: openai_tools(tools), tool_choice: "auto"))

        message = payload.dig("choices", 0, "message") || {}
        calls = Array(message["tool_calls"]).map { |call| function_call_from(call) }
        text = message["content"].to_s
        # Testo assente è NORMALE quando ci sono chiamate (il modello chiede invece di rispondere);
        # è un guasto solo se mancano entrambi. I due possono anche coesistere (verificato dal vivo).
        raise empty_error(payload.dig("choices", 0, "finish_reason")) if calls.empty? && text.empty?

        Turn.new(content: turn_content(text, calls), function_calls: calls, text: text)
      end

      # Speech to text through the same gateway and key. Returns the stripped text, empty when
      # nothing was heard. No language is sent: Whisper detects the spoken one, which is not always
      # the account's. The audio and the text are never logged. CYRA-908
      def transcribe(audio:, filename:)
        with_transport_errors do
          http, req = build_transcription_request(audio, filename)
          response = http.request(req)
          raise error_for(response.code.to_i) unless response.code.to_i == 200

          JSON.parse(response.body).fetch("text", "").to_s.strip
        rescue JSON::ParserError
          raise Error.new("AI server sent an unreadable transcription", code: "R502-LLM-007")
        end
      end

      # SOLO la posizione dell'errore di parsing: il messaggio cita il token inatteso, cioè un pezzo
      # del ticket o della pagina di qualcuno. Nei log non ci va (global/logging.md).
      def self.parser_position(error)
        error.message[/at line \d+ column \d+/] || "posizione sconosciuta"
      end

      private

      def base_body(system, contents, model, max_output_tokens, temperature)
        body = { model: model, messages: Messages.build(system:, contents:),
                 max_tokens: max_output_tokens, temperature: temperature }
        # Senza questo il modello ragiona ad alta voce prima di rispondere: triplica tempo e token,
        # e con un budget corto spende tutto a pensare e risponde vuoto. L'alias `vlm-fast` lo ha
        # già spento lato proxy; qui è la cintura, perché un alias si rinomina senza toccare il codice.
        # vLLM only: a custom provider such as OpenAI rejects unknown fields with a 400 (CYRA-916).
        body[:chat_template_kwargs] = { enable_thinking: false } if self.class.vllm_extras?
        body
      end

      def stream_body(system, contents, response_schema, model, max_output_tokens, temperature)
        body = base_body(system, contents, model, max_output_tokens, temperature)
                 .merge(stream: true, stream_options: { include_usage: true })
        body[:response_format] = response_format(response_schema) if response_schema
        body
      end

      # `strict: true` chiede a vLLM la decodifica guidata: il JSON rispetta lo schema per
      # costruzione, non per buona volontà del modello.
      def response_format(schema)
        { type: "json_schema", json_schema: { name: "response", schema: schema, strict: true } }
      end

      # Legge la risposta a pezzi (Server-Sent Events), yielda ogni delta di testo e ritorna il motivo
      # per cui il modello ha smesso.
      def post_stream(body, deadline_seconds, &block)
        Ai::TokenBudget.check!(Current.organization&.id)
        reset_usage
        finish_reason = nil
        started_at = monotonic_now

        with_transport_errors do
          http, req = build_request(body, accept: "text/event-stream", read_timeout: read_timeout(deadline_seconds))
          http.request(req) do |response|
            raise error_for(response.code.to_i) unless response.code.to_i == 200

            buffer = +""
            response.read_body do |piece|
              buffer << piece
              # Un evento può arrivare spezzato fra due pezzi: si consuma solo fino all'ultimo
              # separatore completo e il resto resta nel buffer.
              while (cut = buffer.index("\n\n"))
                finish_reason = consume(buffer.slice!(0, cut + 2), finish_reason, &block)
              end
              # Dopo ogni pezzo, non prima: un modello lento produce pezzi vivi ma pochi, e il read
              # timeout fra l'uno e l'altro non lo vede mai.
              tighten_deadline(http, deadline_seconds, started_at) if deadline_seconds
            end
            # L'ultimo evento può arrivare senza la riga vuota di chiusura.
            finish_reason = consume(buffer, finish_reason, &block) unless buffer.empty?
          end
        end

        record_usage
        finish_reason
      end

      # The organization's monthly count, for its token cap (CYRA-914).
      def record_usage = Ai::TokenBudget.record(Current.organization&.id, @usage.tokens_input + @usage.tokens_output)

      # Each call starts from zero: a reused client whose next answer brings no usage counts nothing.
      def reset_usage = @usage = Usage.new(tokens_input: 0, tokens_output: 0, model: @model, request_id: nil)

      # Il tetto scaduto ferma lo stream; se non è scaduto, l'attesa SUCCESSIVA si accorcia a quel che
      # resta. Senza questa seconda metà il tetto varrebbe quasi il doppio: `read_timeout` è quanto si
      # aspetta UNA lettura, e riparte intero a ogni pezzo — un pezzo arrivato appena prima della
      # scadenza comprerebbe un altro giro pieno di attesa, e con 70 s dichiarati la chiamata
      # arriverebbe a ~140, oltre i ~100 s dopo i quali il proxy davanti chiude con un 524 muto.
      # `Net::HTTP#read_timeout=` lo consente a socket aperto: aggiorna anche il socket, non solo il
      # valore per la prossima connessione.
      def tighten_deadline(http, deadline_seconds, started_at)
        remaining = deadline_seconds - (monotonic_now - started_at)
        raise deadline_exceeded(deadline_seconds) if remaining <= 0

        http.read_timeout = remaining
      end

      # `empty?` e non `present?`: uno spazio è `blank?` per Rails, e scartarlo incollerebbe fra loro
      # le parole di una risposta che arriva a pezzi.
      def consume(event, finish_reason)
        delta, finish = read_event(event)
        yield delta unless delta.nil? || delta.empty?
        finish || finish_reason
      end

      # Un evento SSE è `data: {json}`; l'ultimo è `data: [DONE]`. Un JSON illeggibile nel mezzo si
      # salta: è un pezzo perso, non un motivo per buttare via la risposta. Keep-alive (`:`) e righe
      # vuote non hanno un `data:` e cadono qui.
      def read_event(event)
        line = event[/^data:\s*(.+)$/, 1]
        return [ nil, nil ] if line.nil? || line.strip == "[DONE]"

        payload = JSON.parse(line)
        @usage = read_usage(payload) if payload["usage"].present?
        choice = payload.dig("choices", 0) || {}
        [ choice.dig("delta", "content"), choice["finish_reason"] ]
      rescue JSON::ParserError
        [ nil, nil ]
      end

      def read_usage(payload)
        usage = payload["usage"] || {}
        Usage.new(tokens_input: usage["prompt_tokens"].to_i, tokens_output: usage["completion_tokens"].to_i,
                  model: payload["model"].presence || @model, request_id: payload["id"])
      end

      def post_json(body)
        Ai::TokenBudget.check!(Current.organization&.id)
        reset_usage
        with_transport_errors do
          http, req = build_request(body, accept: "application/json")
          response = http.request(req)
          raise error_for(response.code.to_i) unless response.code.to_i == 200

          begin
            JSON.parse(response.body).tap do |payload|
              @usage = read_usage(payload) if payload["usage"].present?
              record_usage
            end
          rescue JSON::ParserError => e
            # Corpo illeggibile = guasto del trasporto, non del modello (distinto da R502-LLM-005).
            Rails.logger.error("[Ai::Llm::Client] corpo della risposta illeggibile " \
                               "(#{self.class.parser_position(e)}), #{response.body.to_s.bytesize} byte")
            raise Error.new("Il server AI ha mandato una risposta illeggibile", code: "R502-LLM-007")
          end
        end
      end

      # Uno stream FERMO non manda pezzi, e il tetto totale si misura fra un pezzo e l'altro: senza
      # questo un silenzio del server durerebbe i 300 s del read, non i secondi del deadline.
      def read_timeout(deadline_seconds)
        [ Ai::Llm::Constants::READ_TIMEOUT_SECONDS, deadline_seconds ].compact.min
      end

      # Unico punto che conosce URI, header, TLS e timeout.
      def build_request(body, accept:, read_timeout: Ai::Llm::Constants::READ_TIMEOUT_SECONDS)
        uri = URI.parse("#{@base_url}/chat/completions")
        http = provider_http(uri, read_timeout)

        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{@api_key}"
        req["Content-Type"] = "application/json"
        req["Accept"] = accept
        req.body = body.to_json
        [ http, req ]
      end

      def build_transcription_request(audio, filename)
        uri = URI.parse("#{@base_url}/audio/transcriptions")
        http = provider_http(uri, Ai::Llm::Constants::READ_TIMEOUT_SECONDS)

        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{@api_key}"
        req["Accept"] = "application/json"
        boundary = "cyi-#{SecureRandom.hex(16)}"
        req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        model = Ai::Configuration.current.transcription_model
        raise KeyError, "transcription model not configured" if model.blank?

        req.body = multipart_body(boundary, audio.read, filename, model:, response_format: "json")
        [ http, req ]
      end

      # Built by hand rather than with set_form: that streams the body at send time, where nothing
      # in between (WebMock included) can see it. CYRA-908
      def multipart_body(boundary, bytes, filename, fields)
        parts = fields.map do |name, value|
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
        end
        file_head = "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n" \
                    "Content-Type: audio/wav\r\n\r\n"
        (parts.join + file_head).b + bytes.b + "\r\n--#{boundary}--\r\n".b
      end

      # Scritta una volta per tutte le modalità: un errore di rete grezzo in streaming lascerebbe
      # il messaggio appeso per sempre; in un job diventerebbe un 500 invece del degrado.
      def provider_http(uri, read_timeout)
        Ai::ProviderHttp.build(uri, untrusted: Ai::Configuration.current.untrusted_url?(@base_url),
                                    open_timeout: Ai::Llm::Constants::OPEN_TIMEOUT_SECONDS, read_timeout:)
      end

      def with_transport_errors
        yield
      rescue Ai::ProviderHttp::BlockedAddress => e
        raise Error.new(e.message, code: "R422-AI-008", status: :unprocessable_entity)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error.new("Server AI: timeout", code: "R504-LLM-001", status: :gateway_timeout)
      rescue SystemCallError, OpenSSL::SSL::SSLError, EOFError, SocketError, IOError => e
        raise Error.new("Server AI: errore di rete (#{e.class})", code: "R502-LLM-001")
      end

      # Dal formato dei chiamanti (`functionDeclarations`) a `tools[].function` OpenAI.
      def openai_tools(tools)
        Array(tools).flat_map { |block| Array(block.deep_symbolize_keys[:functionDeclarations]) }
                    .map { |decl| { type: "function", function: decl.slice(:name, :description, :parameters) } }
      end

      # `arguments` è una STRINGA JSON, non un oggetto: un modello può scriverci dentro qualunque cosa,
      # e un JSON storto non deve far cadere il giro — l'attrezzo riceve argomenti vuoti e si lamenta lui.
      def function_call_from(call)
        args = begin
          JSON.parse(call.dig("function", "arguments").to_s)
        rescue JSON::ParserError
          {}
        end
        FunctionCall.new(id: call["id"].to_s, name: call.dig("function", "name").to_s, args: args.is_a?(Hash) ? args : {})
      end

      def turn_content(text, calls)
        parts = []
        parts << { "text" => text } unless text.empty?
        parts += calls.map { |call| { "functionCall" => { "id" => call.id, "name" => call.name, "args" => call.args } } }
        { "role" => "model", "parts" => parts }
      end

      def error_for(code)
        case code
        when 400 then Error.new("Server AI: richiesta rifiutata (schema, alias o payload non validi)", code: "R502-LLM-003")
        when 401, 403 then Error.new("Server AI: auth fallita (#{code})", code: "R502-LLM-002")
        # A CloseYourIt AI key at its monthly limit (CYRA-920): told plainly, not as an outage.
        when 402 then Error.new(I18n.t("ai.limit_reached"), code: "R402-LLM-001", status: :payment_required)
        when 429 then Error.new("Server AI: troppe richieste", code: "R429-LLM-001", status: :too_many_requests)
        when 503 then Error.new("Server AI non disponibile", code: UNAVAILABLE_CODE, status: :service_unavailable)
        else Error.new("Server AI: errore upstream (#{code})", code: "R502-LLM-001")
        end
      end

      def empty_error(finish_reason)
        Error.new("Il server AI non ha prodotto testo (causa: #{finish_reason || 'sconosciuta'})", code: NO_TEXT_CODE)
      end

      def truncated_error
        Rails.logger.error("[Ai::Llm::Client] risposta troncata (length): output #{@usage.tokens_output} token")
        Error.new("Il server AI ha interrotto la risposta perché troppo lunga", code: TRUNCATED_CODE)
      end

      def deadline_exceeded(seconds)
        Error.new("Server AI: risposta troppo lenta (oltre #{seconds} s)", code: "R504-LLM-002", status: :gateway_timeout)
      end

      def parse_model_json(text)
        JSON.parse(text)
      rescue JSON::ParserError => e
        Rails.logger.error("[Ai::Llm::Client] il modello non ha prodotto JSON " \
                           "(#{self.class.parser_position(e)}), #{text.to_s.length} caratteri")
        raise Error.new("Il server AI ha risposto con un testo che non è JSON", code: "R502-LLM-005")
      end

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
