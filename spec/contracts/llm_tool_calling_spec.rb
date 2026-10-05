# frozen_string_literal: true

require "rails_helper"

# Contratto del tool-calling OpenAI-compatible del server AI (LiteLLM davanti a vLLM, alias
# `vlm-fast`). Verificato contro il server VERO il 2026-09-02 (CYRA-765): le fixture in
# spec/fixtures/ai/llm/tool_calling/ sono i corpi mandati e le risposte grezze ricevute, non payload
# scritti a mano. Se il proxy o il modello cambiano il wire e qualcuno rigenera le fixture, è QUI che
# si vede cosa è cambiato, invece che in produzione dentro una chat che smette di rispondere.
#
# Il wire in prosa, con le trappole misurate, sta in docs/contracts/llm-tool-calling.md.
RSpec.describe "Contratto tool-calling del server AI" do
  def fixture(name)
    JSON.parse(Rails.root.join("spec/fixtures/ai/llm/tool_calling/#{name}.json").read)
  end

  # Le stringhe JSON annidate (`function.arguments`, `content` del messaggio tool) si confrontano per
  # contenuto: sono JSON dentro JSON, non testo da riprodurre carattere per carattere.
  def deep_parse(value)
    case value
    when Hash then value.transform_values { |inner| deep_parse(inner) }
    when Array then value.map { |inner| deep_parse(inner) }
    when String then parse_or_keep(value)
    else value
    end
  end

  def parse_or_keep(text)
    JSON.parse(text)
  rescue JSON::ParserError
    text
  end

  describe "turno 1 — la richiesta con gli attrezzi" do
    it "manda tools[].function con parametri JSON Schema e tool_choice auto" do
      request = fixture("request_with_tools")

      expect(request["tools"].map { |t| t.dig("function", "name") }).to eq(%w[list_projects count_open_errors])
      expect(request["tool_choice"]).to eq("auto")
      expect(request["tools"].last.dig("function", "parameters", "required")).to eq([ "project_key" ])
    end

    it "risponde con message.tool_calls[], un id per chiamata e arguments come STRINGA JSON" do
      message = fixture("turn_with_calls").dig("choices", 0, "message")

      expect(message["tool_calls"]).to all(include("id", "type" => "function"))
      expect(message["tool_calls"].map { |c| c.dig("function", "arguments") }).to all(be_a(String))
      expect(message["tool_calls"].map { |c| JSON.parse(c.dig("function", "arguments"))["project_key"] })
        .to eq(%w[CYRA EKETO])
    end

    # Nessuna thoughtSignature da rispedire (era la trappola numero uno di Gemini) e nessun campo
    # provider-specifico obbligatorio: il turno si può RICOSTRUIRE dalle sole tool_calls.
    it "non chiede di rispedire nessuna firma: il turno di soli attrezzi ha content nullo" do
      message = fixture("turn_with_calls").dig("choices", 0, "message")

      expect(message["content"]).to be_nil
      expect(message.to_json).not_to include("thoughtSignature")
      expect(fixture("turn_with_calls").dig("choices", 0, "finish_reason")).to eq("tool_calls")
    end
  end

  describe "turno 2 — le risposte degli attrezzi" do
    it "rispedisce il turno assistant con le sue tool_calls e un messaggio tool per ogni tool_call_id" do
      request = fixture("request_with_responses")
      assistant = request["messages"].find { |m| m["role"] == "assistant" && m["tool_calls"] }
      ids = assistant["tool_calls"].map { |c| c["id"] }
      tool_ids = request["messages"].select { |m| m["role"] == "tool" }.map { |m| m["tool_call_id"] }

      expect(tool_ids).to match_array(ids)
      # Il payload dell'attrezzo viaggia come stringa nel `content`, non come oggetto.
      expect(request["messages"].last["content"]).to be_a(String)
    end

    # L'assistant si rispedisce con `content: null`: il server lo accetta (200 verificato). Pretendere
    # una stringa vuota al suo posto sarebbe un'invenzione, e Ai::Llm::Messages produce proprio nil.
    it "accetta content nullo sul turno assistant rispedito" do
      assistant = fixture("request_with_responses")["messages"].find { |m| m["tool_calls"] }

      expect(assistant).to have_key("content")
      expect(assistant["content"]).to be_nil
    end

    it "chiude con la risposta finale in testo, senza altre tool_calls" do
      choice = fixture("final_text_answer").dig("choices", 0)

      expect(choice["finish_reason"]).to eq("stop")
      expect(choice.dig("message", "tool_calls")).to be_nil
      expect(choice.dig("message", "content")).to include("CYRA", "12", "EKETO", "3")
    end
  end

  # Il ponte fra il contratto e il codice: quello che il client manda e legge deve essere questa forma.
  describe "il client parla questo wire" do
    it "Ai::Llm::Messages ricostruisce il turno 2 esattamente come la fixture" do
      turn = fixture("turn_with_calls").dig("choices", 0, "message")
      calls = turn["tool_calls"].map do |call|
        { "functionCall" => { "id" => call["id"], "name" => call.dig("function", "name"),
                              "args" => JSON.parse(call.dig("function", "arguments")) } }
      end
      replies = turn["tool_calls"].zip([ { "count" => 12 }, { "count" => 3 } ]).map do |call, payload|
        { "functionResponse" => { "id" => call["id"], "name" => call.dig("function", "name"), "response" => payload } }
      end

      messages = Ai::Llm::Messages.build(
        system: "s",
        contents: [ { "role" => "user", "parts" => [ { "text" => "d" } ] },
                    { "role" => "model", "parts" => calls },
                    { "role" => "user", "parts" => replies } ]
      )

      expect(messages.map { |m| m[:role] }).to eq(%w[system user assistant tool tool])
      # Confronto SEMANTICO: `arguments` e il `content` del messaggio tool sono stringhe JSON, e la
      # spaziatura di chi le ha serializzate (il modello, o Ruby) non fa parte del contratto.
      expect(deep_parse(messages.as_json.last(3))).to eq(deep_parse(fixture("request_with_responses")["messages"].last(3)))
    end
  end
end
