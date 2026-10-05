# frozen_string_literal: true

require "rails_helper"

# Contratto del wire `POST /chat/completions` del server AI di casa (LiteLLM davanti a vLLM sul DGX),
# congelato dalle risposte VERE del proxy (2026-09-03, alias `vlm-fast`, CYRA-764). Le fixture in
# spec/fixtures/ai/litellm/chat/ sono i corpi grezzi di quelle chiamate, catturati con una chiave di
# sviluppo mai committata: se un domani il proxy o vLLM cambiano il wire e qualcuno le rigenera, è QUI
# che si vede cosa è cambiato, invece che in produzione dentro un salvataggio che risponde 503.
#
# Le tre cose che non stanno nella doc e che il revisore dà per scontate: il ragionamento si spegne
# davvero con `chat_template_kwargs` (reasoning_tokens = 0), il `finish_reason` sta in un chunk a
# parte PRIMA di quello con `usage`, e un alias sconosciuto è un 400 con `Invalid model name`, non un 404.
# Il wire in prosa sta in docs/contracts/litellm-chat-completions.md.
#
# Dal CYRA-766 il client sopra questo wire è UNO SOLO (`Ai::Llm::Client`), col profilo di credenziali
# del revisore: le fixture non cambiano, cambia chi le legge.
RSpec.describe "Contratto chat/completions di LiteLLM (server AI di casa)" do
  def fixture(name) = Rails.root.join("spec/fixtures/ai/litellm/chat/#{name}").read

  def events(name)
    fixture(name).split("\n\n").filter_map { |event| event[/^data:\s*(.+)$/, 1] }
  end

  def chunks(name) = events(name).reject { |line| line == "[DONE]" }.map { |line| JSON.parse(line) }

  describe "lo stream" do
    it "è una sequenza di `data: {json}` separati da riga vuota, chiusa da `data: [DONE]`" do
      expect(events("stream_verdict_accept.sse").last).to eq("[DONE]")
      expect(chunks("stream_verdict_accept.sse")).to all(include("object" => "chat.completion.chunk"))
    end

    it "il testo arriva in `choices[0].delta.content`, a pezzi, e ricomposto è il JSON dello schema" do
      text = chunks("stream_verdict_accept.sse").filter_map { |c| c.dig("choices", 0, "delta", "content") }.join
      expect(JSON.parse(text)).to include("format" => "troubleshooting", "verdict" => "accept", "violations" => [])
    end

    it "il `finish_reason` sta nel penultimo chunk utile e l'`usage` in uno a parte, dopo" do
      all = chunks("stream_verdict_accept.sse")
      finish_index = all.index { |c| c.dig("choices", 0, "finish_reason") == "stop" }
      usage_index = all.index { |c| c["usage"].present? }
      expect(finish_index).to be < usage_index
      expect(all[usage_index]["usage"]).to include("prompt_tokens", "completion_tokens")
    end

    it "con il ragionamento spento i reasoning_tokens sono zero: il budget va tutto alla risposta" do
      usage = chunks("stream_verdict_accept.sse").find { |c| c["usage"].present? }["usage"]
      expect(usage.dig("completion_tokens_details", "reasoning_tokens")).to eq(0)
    end

    it "il modello nei chunk è l'ALIAS, non il nome HuggingFace: `ai_review_model` registra l'alias" do
      expect(chunks("stream_verdict_accept.sse").first["model"]).to eq(Ai::Llm::Constants::MODEL)
    end

    it "un rifiuto porta le violazioni nella forma dello schema" do
      text = chunks("stream_verdict_reject.sse").filter_map { |c| c.dig("choices", 0, "delta", "content") }.join
      verdict = JSON.parse(text)
      expect(verdict).to include("format" => "unknown", "verdict" => "reject")
      expect(verdict["violations"].first).to include("code" => "K01")
    end

    it "quando lo spazio finisce il JSON è tagliato e il `finish_reason` è `length`" do
      all = chunks("stream_length_truncated.sse")
      text = all.filter_map { |c| c.dig("choices", 0, "delta", "content") }.join
      expect(all.map { |c| c.dig("choices", 0, "finish_reason") }.compact).to eq([ "length" ])
      expect { JSON.parse(text) }.to raise_error(JSON::ParserError)
    end
  end

  describe "il client sopra quel wire" do
    let(:client) { Ai::Llm::Client.new(credentials: :knowledge_review, api_key: "k", base_url: "https://ai.test/v1") }
    let(:url) { "https://ai.test/v1/chat/completions" }

    def call(schema: Knowledge::Review::SCHEMA)
      client.generate_content(system: "s", contents: [ { role: "user", parts: [ { text: "u" } ] } ], response_schema: schema)
    end

    it "legge il verdetto vero e registra l'usage" do
      stub_request(:post, url).to_return(status: 200, body: fixture("stream_verdict_accept.sse"))

      expect(call).to include("verdict" => "accept")
      expect(client.usage.tokens_output).to eq(30)
      expect(client.usage.model).to eq("vlm-fast")
    end

    it "il troncamento vero è R502-LLM-006" do
      stub_request(:post, url).to_return(status: 200, body: fixture("stream_length_truncated.sse"))

      expect { call }.to raise_error(Ai::Llm::Client::Error) { |e| expect(e.code).to eq(Ai::Llm::Client::TRUNCATED_CODE) }
    end

    it "l'alias sconosciuto è un 400 «Invalid model name» → R502-LLM-003, definitivo" do
      expect(JSON.parse(fixture("error_400_invalid_model.json")).dig("error", "message")).to include("Invalid model name")
      stub_request(:post, url).to_return(status: 400, body: fixture("error_400_invalid_model.json"))

      expect { call }.to raise_error(Ai::Llm::Client::Error) { |e|
        expect(e.code).to eq("R502-LLM-003")
        expect(TransientFailure === e).to be(false)
      }
    end

    it "la chiave sconosciuta è un 401 `token_not_found_in_db` → R502-LLM-002, definitivo" do
      expect(JSON.parse(fixture("error_401.json")).dig("error", "type")).to eq("token_not_found_in_db")
      stub_request(:post, url).to_return(status: 401, body: fixture("error_401.json"))

      expect { call }.to raise_error(Ai::Llm::Client::Error) { |e|
        expect(e.code).to eq("R502-LLM-002")
        expect(TransientFailure === e).to be(false)
      }
    end
  end
end
