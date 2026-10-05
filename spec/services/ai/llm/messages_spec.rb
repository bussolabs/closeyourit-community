# spec/services/ai/llm/messages_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Llm::Messages do
  it "mette il system in testa e traduce i ruoli user/model in user/assistant" do
    messages = described_class.build(
      system: "regole",
      contents: [ { role: "user", parts: [ { text: "ciao" } ] },
                  { role: "model", parts: [ { text: "salve" } ] } ]
    )

    expect(messages).to eq([
      { role: "system", content: "regole" },
      { role: "user", content: "ciao" },
      { role: "assistant", content: "salve" }
    ])
  end

  it "concatena i part di testo e traduce inline_data in image_url con data URI" do
    messages = described_class.build(
      system: "s",
      contents: [ { role: "user", parts: [ { text: "guarda" }, { inline_data: { mime_type: "image/png", data: "QUJD" } } ] } ]
    )

    expect(messages.last).to eq(
      role: "user",
      content: [ { type: "text", text: "guarda" },
                 { type: "image_url", image_url: { url: "data:image/png;base64,QUJD" } } ]
    )
  end

  it "traduce il turno del modello con functionCall in tool_calls e la functionResponse in un messaggio tool" do
    turn = { "role" => "model",
             "parts" => [ { "functionCall" => { "id" => "call_1", "name" => "list_projects", "args" => { "q" => "x" } } } ] }
    reply = { role: "user",
              parts: [ { functionResponse: { id: "call_1", name: "list_projects", response: { "items" => [] } } } ] }

    messages = described_class.build(system: "s", contents: [ { role: "user", parts: [ { text: "elenca" } ] }, turn, reply ])

    expect(messages[2]).to eq(
      role: "assistant", content: nil,
      tool_calls: [ { id: "call_1", type: "function", function: { name: "list_projects", arguments: { "q" => "x" }.to_json } } ]
    )
    expect(messages[3]).to eq(role: "tool", tool_call_id: "call_1", content: { "items" => [] }.to_json)
  end

  it "accetta chiavi stringa e simbolo indifferentemente" do
    messages = described_class.build(system: "s", contents: [ { "role" => "user", "parts" => [ { "text" => "a" } ] } ])
    expect(messages.last).to eq(role: "user", content: "a")
  end
end
