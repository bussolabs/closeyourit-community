# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Github::Webhooks", type: :request do
  let(:secret) { "whsec_test" }
  let(:body) { { ref: "refs/tags/v1.0.0", repository: { id: 123 } }.to_json }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GH_WEBHOOK_SECRET").and_return(secret)
  end

  def signature(payload, key: secret)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", key, payload)}"
  end

  def post_webhook(event:, payload:, headers: {})
    post "/github/webhook", params: payload,
         headers: { "Content-Type" => "application/json", "X-GitHub-Event" => event }.merge(headers)
  end

  it "firma valida → 204 e accoda WebhookJob con evento e payload" do
    expect do
      post_webhook(event: "push", payload: body, headers: { "X-Hub-Signature-256" => signature(body) })
    end.to have_enqueued_job(Github::WebhookJob)
      .with(event: "push", payload: { "ref" => "refs/tags/v1.0.0", "repository" => { "id" => 123 } })

    expect(response).to have_http_status(:no_content)
  end

  it "firma errata → 404 e nessun job accodato" do
    expect do
      post_webhook(event: "push", payload: body, headers: { "X-Hub-Signature-256" => signature(body, key: "wrong") })
    end.not_to have_enqueued_job(Github::WebhookJob)

    expect(response).to have_http_status(:not_found)
  end

  it "firma assente → 404" do
    post_webhook(event: "push", payload: body)

    expect(response).to have_http_status(:not_found)
  end

  describe "consegne malformate (il webhook non deve andare in errore)" do
    it "contenuto che non è un oggetto → 204 e al programma arriva una consegna vuota" do
      lista = "[1, 2, 3]"

      expect do
        post_webhook(event: "push", payload: lista, headers: { "X-Hub-Signature-256" => signature(lista) })
      end.to have_enqueued_job(Github::WebhookJob).with(event: "push", payload: {})

      expect(response).to have_http_status(:no_content)
    end

    it "contenuto che non è JSON → 204 e al programma arriva una consegna vuota" do
      spazzatura = "{non-json"

      expect do
        post "/github/webhook", params: spazzatura,
             headers: { "Content-Type" => "application/octet-stream", "X-GitHub-Event" => "push",
                        "X-Hub-Signature-256" => signature(spazzatura) }
      end.to have_enqueued_job(Github::WebhookJob).with(event: "push", payload: {})

      expect(response).to have_http_status(:no_content)
    end

    it "contenuto vuoto con firma valida → 204 e nessun errore" do
      expect do
        post "/github/webhook", params: "",
             headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "push",
                        "X-Hub-Signature-256" => signature("") }
      end.to have_enqueued_job(Github::WebhookJob).with(event: "push", payload: {})

      expect(response).to have_http_status(:no_content)
    end
  end
end
