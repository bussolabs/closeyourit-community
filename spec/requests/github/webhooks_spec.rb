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

  it "records the signed body and enqueues its receipt" do
    expect do
      post_webhook(event: "push", payload: body, headers: { "X-Hub-Signature-256" => signature(body) })
    end.to have_enqueued_job(Github::WebhookJob)
      .with(delivery_id: kind_of(String))

    expect(response).to have_http_status(:no_content)
    expect(Github::WebhookDelivery.last.body).to eq(body)
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
      end.to have_enqueued_job(Github::WebhookJob).with(delivery_id: kind_of(String))

      expect(response).to have_http_status(:no_content)
    end

    it "contenuto che non è JSON → 204 e al programma arriva una consegna vuota" do
      spazzatura = "{non-json"

      expect do
        post "/github/webhook", params: spazzatura,
             headers: { "Content-Type" => "application/octet-stream", "X-GitHub-Event" => "push",
                        "X-Hub-Signature-256" => signature(spazzatura) }
      end.to have_enqueued_job(Github::WebhookJob).with(delivery_id: kind_of(String))

      expect(response).to have_http_status(:no_content)
    end

    it "contenuto vuoto con firma valida → 204 e nessun errore" do
      expect do
        post "/github/webhook", params: "",
             headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "push",
                        "X-Hub-Signature-256" => signature("") }
      end.to have_enqueued_job(Github::WebhookJob).with(delivery_id: kind_of(String))

      expect(response).to have_http_status(:no_content)
    end
  end

  def deliver(body, id: "delivery-1", key: secret)
    post_webhook(event: "push", payload: body,
                 headers: { "X-GitHub-Delivery" => id, "X-Hub-Signature-256" => signature(body, key:) })
  end

  it "acknowledges immediate duplicates without enqueueing again" do
    deliver(body)
    expect { deliver(body) }.not_to have_enqueued_job(Github::WebhookJob)
    expect(response).to have_http_status(:no_content)
    expect(Github::WebhookDelivery.count).to eq(1)
  end

  it "does not repeat a completed deletion when the same request returns" do
    installation = create(:github_installation)
    organization = installation.organization
    github_id = installation.installation_id
    payload = { action: "deleted", installation: { id: github_id } }.to_json
    headers = { "X-GitHub-Delivery" => "deletion", "X-Hub-Signature-256" => signature(payload) }

    perform_enqueued_jobs do
      post_webhook(event: "installation", payload:, headers:)
    end
    expect(Github::Installation.exists?(installation.id)).to be(false)
    replacement = create(:github_installation, organization:, installation_id: github_id)

    expect do
      perform_enqueued_jobs do
        post_webhook(event: "installation", payload:, headers:)
      end
    end.not_to have_enqueued_job(Github::WebhookJob)
    expect(response).to have_http_status(:no_content)
    expect(Github::Installation.exists?(replacement.id)).to be(true)
  end

  it "recognizes a signed body even with a changed or missing delivery identifier" do
    deliver(body)
    expect { deliver(body, id: "changed") }.not_to have_enqueued_job(Github::WebhookJob)
    expect { deliver(body, id: nil) }.not_to have_enqueued_job(Github::WebhookJob)
    expect(Github::WebhookDelivery.count).to eq(1)
  end

  it "does not let an invalid signature poison a subsequent valid delivery" do
    expect { deliver(body, key: "wrong") }.not_to change(Github::WebhookDelivery, :count)
    expect { deliver(body) }.to have_enqueued_job(Github::WebhookJob)
  end

  it "rejects reuse of an identifier with different content without overwriting the receipt" do
    deliver(body)
    expect { deliver('{"ref":"other"}') }.not_to have_enqueued_job(Github::WebhookJob)
    expect(response).to have_http_status(:conflict)
    expect(Github::WebhookDelivery.last.body).to eq(body)
  end

  it "accepts distinct signed contents" do
    deliver(body)
    expect { deliver('{"ref":"other"}', id: "other") }.to have_enqueued_job(Github::WebhookJob)
    expect(Github::WebhookDelivery.count).to eq(2)
  end

  it "keeps an accepted receipt recoverable when enqueueing raises" do
    allow(Github::WebhookJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")
    deliver(body)
    expect(response).to have_http_status(:no_content)
    expect(Github::WebhookDelivery.last.enqueued_at).to be_nil
    allow(Github::WebhookJob).to receive(:perform_later).and_call_original
    expect { Github::RecoverWebhooksJob.perform_now }.to have_enqueued_job(Github::WebhookJob)
  end

  # CYRA-1164 — the end of a CI job, signed by GitHub, becomes a stored outcome of the connected repository.
  describe "workflow_job" do
    let(:repository) { create(:github_repository) }

    def job_body(repo_id: repository.repo_id)
      { action: "completed", repository: { id: repo_id }, installation: { id: repository.installation.installation_id },
        workflow_job: { id: 501, run_id: 601, run_attempt: 1, head_sha: "abc", head_branch: "main", name: "test",
                        workflow_name: "ci", conclusion: "success", created_at: "2026-11-05T10:00:00Z",
                        started_at: "2026-11-05T10:02:00Z", completed_at: "2026-11-05T10:07:00Z" } }.to_json
    end

    def deliver_job(payload)
      perform_enqueued_jobs do
        post_webhook(event: "workflow_job", payload:,
                     headers: { "X-GitHub-Delivery" => "job-1", "X-Hub-Signature-256" => signature(payload) })
      end
    end

    it "stores the outcome of a signed delivery" do
      deliver_job(job_body)

      expect(response).to have_http_status(:no_content)
      expect(Github::CiJobRun.sole).to have_attributes(github_job_id: 501, conclusion: "success", head_branch: "main")
      expect(Github::CiJobRun.sole.ci_job.repository).to eq(repository)
    end

    it "receives the delivery of a repository not connected, and stores nothing" do
      deliver_job(job_body(repo_id: 424_242))

      expect(response).to have_http_status(:no_content)
      expect(Github::CiJobRun.count).to eq(0)
    end

    it "receives the delivery of a suspended organization, and stores nothing" do
      repository.installation.organization.update!(suspended_at: Time.current)

      deliver_job(job_body)

      expect(response).to have_http_status(:no_content)
      expect(Github::CiJobRun.count).to eq(0)
    end
  end
end
