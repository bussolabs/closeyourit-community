# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Structured do
  let(:client) { instance_double(Ai::Llm::Client) }
  let(:schema) { { type: "object", properties: { ok: { type: "boolean" } }, required: %w[ok] } }

  it "impacchetta il testo come unico turno utente e ritorna l'hash del modello" do
    expect(client).to receive(:generate_content).with(
      system: "istruzioni",
      contents: [ { role: "user", parts: [ { text: "domanda" } ] } ],
      response_schema: schema
    ).and_return({ "ok" => true })

    result = described_class.call(client: client, system: "istruzioni", user: "domanda", schema: schema)

    expect(result).to eq({ "ok" => true })
  end

  # Il dialetto dei chiamanti vuole mime type e base64 separati (`inline_data`); è Ai::Llm::Messages
  # a ricomporne la data URL per il wire OpenAI. È la conversione che, se manca, fa perdere le
  # immagini in silenzio — il modello riceve il solo testo e risponde lo stesso.
  it "traduce le immagini in inline_data, dopo il testo" do
    expect(client).to receive(:generate_content).with(
      system: "istruzioni",
      contents: [ { role: "user", parts: [
        { text: "domanda" },
        { inline_data: { mime_type: "image/png", data: "QUJD" } }
      ] } ],
      response_schema: schema
    ).and_return({})

    described_class.call(client: client, system: "istruzioni", user: "domanda", schema: schema,
                         images: [ { mime_type: "image/png", data: "QUJD" } ])
  end

  it "inoltra modello e tetto di output solo quando richiesti" do
    expect(client).to receive(:generate_content)
      .with(hash_including(model: "modello-alternativo", max_output_tokens: 3072))
      .and_return({})

    described_class.call(client: client, system: "s", user: "u", schema: schema,
                         max_output_tokens: 3072, model: "modello-alternativo")
  end

  it "omette modello e tetto quando non passati, così valgono i default del client" do
    expect(client).to receive(:generate_content) do |args|
      expect(args).not_to have_key(:model)
      expect(args).not_to have_key(:max_output_tokens)
      {}
    end

    described_class.call(client: client, system: "s", user: "u", schema: schema)
  end

  # Gli errori del fornitore appartengono al service, che sa quale messaggio mostrare e con quale
  # codice: intercettarli qui li appiattirebbe tutti allo stesso esito.
  it "non intercetta gli errori del client" do
    allow(client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("giù", code: "R502-LLM-001"))

    expect { described_class.call(client: client, system: "s", user: "u", schema: schema) }
      .to raise_error(Ai::Llm::Client::Error)
  end
end
