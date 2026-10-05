# frozen_string_literal: true

module Assistant
  # Il giro di domande e risposte fra il modello e i nostri attrezzi.
  #
  # Il modello riceve la domanda e l'elenco degli attrezzi; se chiede di usarne uno (o più), li
  # eseguiamo sul perimetro congelato e gli rimandiamo i risultati; si ripete finché smette di
  # chiedere e produce la risposta. Da qui la catena "quali progetti ho → quanti errori per ognuno →
  # risposta", che con una sola chiamata al modello non sarebbe possibile.
  #
  # Due regole del wire sono responsabilità di questo loop e non del client:
  #   - il turno del modello si rimanda INTEGRALE (`turn.content`): il client lo ritraduce in
  #     `assistant` + `tool_calls` con gli stessi id, e ricostruirlo a mano li perderebbe;
  #   - a ogni chiamata deve corrispondere UNA risposta, con lo stesso id (sul wire OpenAI un
  #     messaggio `role: tool` per ogni `tool_call_id`). Rispondendo a meno chiamate non arriva
  #     alcun errore: il modello ripete la chiamata rimasta e il giro va a vuoto (CYRA-765).
  class Converse < ApplicationService
    # Tetto di giri. Non è una stima di quanti ne servano (le catene osservate ne usano 2-3): è il
    # freno che impedisce a un modello confuso di rimbalzare fra attrezzi finché non finisce la quota.
    MAX_TURNS = 5

    # Tetto sul contesto mandato al modello, misurato sui caratteri del payload perché i token non si
    # conoscono senza tokenizzare (regola spannometrica del settore: ~4 caratteri per token, quindi
    # circa 20k token). Serve perché il tetto sui giri da solo non basta: cinque giri di attrezzi che
    # rispondono molto — venti ticket, tre commenti l'uno — gonfiano prompt e conto senza che il
    # numero di giri lo dica. Nell'uso normale non scatta mai; è un freno d'emergenza, non un limite
    # di lavoro. Vale sull'INTERO contesto (storia compresa), che è ciò che si paga a ogni giro.
    MAX_CONTEXT_CHARS = 80_000

    Answer = Data.define(:text, :tools_used)

    def initialize(context:, question:, history: [], client: nil, catalog: nil, focus: nil)
      @context = context
      @question = question.to_s.strip
      @history = history
      @client = client
      @catalog = catalog
      @focus = focus
    end

    def call
      return Result.err(::Ai::Feature.disabled_error(:assistant_tools)) if ::Ai::Feature.disabled?(:assistant_tools)
      return blank_question_error if @question.blank?

      # L'AI la offre il sistema, con una chiave sola (CYRA-765): niente più chiave per
      # organizzazione. Il freno del god resta sopra: si arriva qui solo se l'interruttore
      # generale è acceso.
      client = @client || ::Ai::Llm::Client.new

      converse(client)
    rescue ::Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # Chiave o indirizzo del server AI assenti: è una configurazione mancante, non un guasto del
      # fornitore. Va detto così a chi chiede, invece di lasciar salire un 500.
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    end

    private

    def converse(client)
      contents = @history + [ { role: "user", parts: [ { text: @question } ] } ]
      tools_used = []

      MAX_TURNS.times do
        return too_much_context_error(tools_used) if oversized?(contents)

        turn = client.generate_with_tools(system: system_prompt, contents: contents,
                                          tools: Tools::Registry.declarations(@context))
        return Result.ok(Answer.new(text: turn.text, tools_used: tools_used)) if turn.function_calls.empty?

        tools_used.concat(turn.function_calls.map(&:name))
        contents += [ turn.content, { role: "user", parts: run_all(turn.function_calls) } ]
      end

      too_many_turns_error(tools_used)
    end

    # Una functionResponse per OGNI chiamata, nello stesso ordine e con lo stesso id.
    # Un attrezzo che fallisce non interrompe la conversazione: l'errore torna al modello come
    # risultato, così può dirlo a chi ha chiesto invece di far cadere tutto.
    def run_all(function_calls)
      function_calls.map do |function_call|
        result = Tools::Registry.run(name: function_call.name, args: function_call.args, context: @context)
        { functionResponse: { id: function_call.id, name: function_call.name, response: result } }
      end
    end

    # Misurato PRIMA della chiamata: superato il tetto ci si ferma senza spendere il giro che lo
    # sforerebbe. È la serializzazione vera, quella che parte nel corpo della richiesta.
    def oversized?(contents) = contents.to_json.size > MAX_CONTEXT_CHARS


    # Il prompt sa se il perimetro si è ristretto dopo la domanda (CYRA-812): è l'unico modo perché
    # il modello lo dica a chi ha chiesto invece di rispondere con quel che resta e basta.
    def system_prompt
      @system_prompt ||= Tools::SystemPrompt.call(scope_reduced: @context.scope_reduced, catalog: @catalog,
                                                  proposals: @context.proposals?, focus: @focus)
    end

    def blank_question_error
      Result.err(AppError.new(I18n.t("assistant.errors.blank"),
                              code: "R422-ASSISTANT-001", status: :unprocessable_content))
    end

    # Il tetto raggiunto è un esito, non un'eccezione: chi chiama deve poterlo dire a chi ha scritto
    # ("non ci sono riuscito") invece di mostrare una risposta a metà o un errore di sistema.
    def too_many_turns_error(tools_used)
      Rails.logger.warn("[assistant] tetto di #{MAX_TURNS} giri raggiunto, attrezzi: #{tools_used.join(', ')}")
      Result.err(AppError.new(I18n.t("assistant.errors.too_many_turns"),
                              code: "R422-ASSISTANT-002", status: :unprocessable_content))
    end

    # Codice distinto dal tetto dei giri benché il messaggio a schermo sia parente: nei log servono
    # separati, perché si curano in modo diverso — l'uno guarda un modello che gira a vuoto, l'altro
    # attrezzi che rispondono troppo.
    def too_much_context_error(tools_used)
      Rails.logger.warn("[assistant] contesto oltre #{MAX_CONTEXT_CHARS} caratteri, " \
                        "attrezzi: #{tools_used.join(', ')}")
      Result.err(AppError.new(I18n.t("assistant.errors.too_much_context"),
                              code: "R422-ASSISTANT-003", status: :unprocessable_content))
    end
  end
end
