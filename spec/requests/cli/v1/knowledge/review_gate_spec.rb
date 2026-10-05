# frozen_string_literal: true

require "rails_helper"

# CYRA-764 — la CLI stampa solo `code: message`: il messaggio deve già dire cosa correggere, e i
# details portano l'elenco per chi legge il JSON.
RSpec.describe "Cli::V1::Knowledge — revisore automatico", type: :request, knowledge_review: true do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:chat_url) { "https://ai.test/v1/chat/completions" }

  before { create(:membership, account:, organization:, role: :owner) }

  # Il canale intero, dal proxy in giù: qui il revisore è quello vero, con il server AI finto.
  around do |example|
    original = { "AI_API_KEY" => ENV["AI_API_KEY"], "CHAT_BASE_URL" => ENV["CHAT_BASE_URL"] }
    ENV["AI_API_KEY"] = "k"
    ENV["CHAT_BASE_URL"] = "https://ai.test/v1"
    example.run
    original.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def sse(payload)
    "data: #{{ choices: [ { delta: { content: payload.to_json }, finish_reason: "stop" } ], model: "qwen" }.to_json}\n\ndata: [DONE]\n\n"
  end

  let(:good_page) do
    { project: project.key, title: "Rails — la cache non tiene niente in prova", kind: "note", tags: %w[rails test],
      body: "Formato: troubleshooting\n\n## Sintomo\n`boom`\n## Causa\nx\n## Correzione\ny\n## Verifica\nz" }
  end

  it "il pre-check rifiuta senza chiamare il server: 422 con codice, messaggio e details" do
    stub = stub_request(:post, chat_url)

    post "/cli/v1/knowledge/pages", params: good_page.merge(title: "senza area", tags: []), headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    error = response.parsed_body["error"]
    expect(error["code"]).to eq("R422-KNOWLEDGE-013")
    expect(error["message"]).to include("K02 —").and include("K11 —")
    expect(error["details"]["violations"].map { |v| v["code"] }).to eq(%w[K02 K11])
    expect(stub).not_to have_been_requested
  end

  it "il modello accetta: 201 e la pagina porta formato e modello" do
    stub_request(:post, chat_url).to_return(status: 200, body: sse(format: "troubleshooting", verdict: "accept", violations: [], suggested_kind: "note", suggested_title: "x"))

    post "/cli/v1/knowledge/pages", params: good_page, headers: headers

    expect(response).to have_http_status(:created)
    expect(response.parsed_body["data"]["ai_review_format"]).to eq("troubleshooting")
    expect(response.parsed_body["data"]["ai_review_verdict"]).to eq("accepted")
  end

  it "il modello rifiuta: 422 con le sue violazioni" do
    stub_request(:post, chat_url).to_return(status: 200, body: sse(format: "troubleshooting", verdict: "reject",
                                                                    violations: [ { code: "T02", message: "La causa manca." } ],
                                                                    suggested_kind: "note", suggested_title: "x"))

    expect { post "/cli/v1/knowledge/pages", params: good_page, headers: headers }.not_to change(Knowledge::Page, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["message"]).to include("T02 — La causa manca.")
  end

  it "server AI giù: 503 R503-KNOWLEDGE-001 con la causa" do
    stub_request(:post, chat_url).to_return(status: 503, body: "{}")

    post "/cli/v1/knowledge/pages", params: good_page, headers: headers

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["error"]["code"]).to eq("R503-KNOWLEDGE-001")
    expect(response.parsed_body["error"]["details"]["cause"]).to eq("R503-LLM-001")
  end

  it "la pubblicazione per chiave passa dallo stesso gate" do
    stub_request(:post, chat_url).to_return(status: 200, body: sse(format: "procedure", verdict: "reject",
                                                                    violations: [ { code: "P01", message: "Meno di tre passi." } ],
                                                                    suggested_kind: "guide", suggested_title: "x"))

    put "/cli/v1/projects/#{project.id}/knowledge/publications/kb:deploy",
        params: { title: "Nuxt — deploy", body: "Formato: procedura\n1. a", kind: "guide", tags: %w[nuxt deploy] }, headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-013")
    expect(Knowledge::Page.count).to eq(0)
  end
end
