# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AgentTicketQueueDeferrals (automator)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }
  let(:selection_token) { Agents::TicketQueues::Selection.issue(ticket:, host:) }
  let(:params) { { selection_token:, host_id: host.id, reason: "temporary_failure" } }
  # Host-first (CYAU-84): coda appiattita, senza agent_id nell'URL.
  let(:path) { "/api/v1/ticket_queue/deferrals" }

  before do
    # B.5 — scope per-host: la registrazione conia il service account dell'host senza progetti (fail-closed);
    # il defer lo ammette solo se quel SA vede il progetto, quindi qui gli concediamo la visibilità.
    create(:project_membership, account: host.service_account, project:)
  end

  it "crea un defer org/host/ticket/fase-scoped con ragione e retry_at server-side" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)

    travel_to(now) do
      expect { post path, params:, headers:, as: :json }
        .to change(Agents::TicketQueueDeferral, :count).by(1)
    end

    expect(response).to have_http_status(:created)
    # Host-first (CYAU-84/92): il deferral è keyed su host + ticket + execution_phase (firmata nel token,
    expect(response.parsed_body.fetch("data")).to include(
      "ticket" => ticket.code,
      "host_id" => host.id,
      "execution_phase" => "triage",
      "reason" => "temporary_failure",
      "retry_at" => (now + 5.minutes).iso8601(3),
      "replayed" => false
    )
    expect(Agents::TicketQueueDeferral.sole).to have_attributes(
      organization:, host:, ticket:, execution_phase: "triage",
      reason: "temporary_failure", retry_at: now + 5.minutes
    )
  end

  it "applica la policy esplicita X-1, X e X+1 senza accettare retry_at o costi dal client" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    candidates = allow_n_plus_one { 3.times.map { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) } }
    reasons = %w[temporary_failure preflight_blocked needs_clarification]

    travel_to(now) do
      allow_n_plus_one do
        candidates.zip(reasons).each do |candidate, reason|
          token = Agents::TicketQueues::Selection.issue(ticket: candidate, host:)
          post path,
               params: params.merge(selection_token: token, reason:, retry_at: 1.year.from_now, estimated_cost: 999),
               headers:, as: :json
          expect(response).to have_http_status(:created)
        end
      end
    end

    expect(Agents::TicketQueueDeferral.order(:retry_at).pluck(:reason, :retry_at)).to contain_exactly(
      [ "temporary_failure", now + 5.minutes ],
      [ "preflight_blocked", now + 30.minutes ],
      [ "needs_clarification", now + 6.hours ]
    )
  end

  it "rifiuta una ragione libera senza creare il record" do
    expect { post path, params: params.merge(reason: "aspetta fino a domani"), headers:, as: :json }
      .not_to change(Agents::TicketQueueDeferral, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-QUEUE-003")
  end

  it "rende il replay idempotente senza estendere indefinitamente il backoff" do
    first_retry_at = nil
    now = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now, now + 4.minutes)

    travel_to(now) do
      post path, params:, headers:, as: :json
      first_retry_at = response.parsed_body.dig("data", "retry_at")
    end
    travel_to(now + 4.minutes) do
      expect { post path, params:, headers:, as: :json }
        .not_to change(Agents::TicketQueueDeferral, :count)
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to include(
      "replayed" => true, "reason" => "temporary_failure", "retry_at" => first_retry_at
    )
    expect(Agents::TicketQueueDeferral.sole.retry_at.iso8601(3)).to eq(first_retry_at)
  end

  it "dà a due host il proprio deferral col proprio token host-bound (keyed per-host)" do
    other = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-2", platform: "linux", arch: "amd64"
    ).value
    other_host = other.fetch(:host)
    create(:project_membership, account: other_host.service_account, project:)
    other_headers = { "Authorization" => "Bearer #{other.fetch(:secret)}" }
    other_token = Agents::TicketQueues::Selection.issue(ticket:, host: other_host)

    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)

    expect do
      post path, params: params.merge(selection_token: other_token, host_id: other_host.id), headers: other_headers, as: :json
    end.to change(Agents::TicketQueueDeferral, :count).by(1)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "replayed")).to be(false)
    expect(Agents::TicketQueueDeferral.where(ticket:).pluck(:host_id)).to contain_exactly(host.id, other_host.id)
  end

  it "mantiene la prima decisione con un nuovo token e una ragione diversa durante il backoff" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)

    travel_to(now) { post path, params:, headers:, as: :json }
    original = response.parsed_body.fetch("data")
    second_token = travel_to(now + 1.second) do
      Agents::TicketQueues::Selection.issue(ticket:, host:)
    end
    expect(second_token).not_to eq(selection_token)

    travel_to(now + 1.second) do
      expect do
        post path,
             params: params.merge(selection_token: second_token, reason: "needs_clarification"),
             headers:, as: :json
      end.not_to change(Agents::TicketQueueDeferral, :count)
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to include(
      "replayed" => true,
      "reason" => original.fetch("reason"),
      "retry_at" => original.fetch("retry_at")
    )
    expect(Agents::TicketQueueDeferral.sole).to have_attributes(
      reason: "temporary_failure", retry_at: Time.iso8601(original.fetch("retry_at"))
    )
  end

  it "rifiuta token mancante, alterato e scaduto" do
    expired = Agents::TicketQueues::Selection.issue(ticket:, host:, expires_in: 1.second)

    expect do
      post path, params: params.except(:selection_token), headers:, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      post path, params: params.merge(selection_token: "#{selection_token}alterato"), headers:, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      travel 2.seconds do
        post path, params: params.merge(selection_token: expired), headers:, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end
    end.not_to change(Agents::TicketQueueDeferral, :count)

    expect(response.parsed_body.dig("error", "code")).to eq("R422-QUEUE-001")
  end

  it "non rivela selezioni di un altro tenant o legate a un altro host" do
    # Host-first (CYAU-84): niente agent_id nell'URL; l'anti-BOLA è il token host-bound — una selezione di
    # un'altra org o di un altro host non combacia con l'organization/host autenticato → R404-QUEUE-001.
    foreign_organization = create(:organization)
    foreign_project = create(:project, organization: foreign_organization)
    create(:github_repository, project: foreign_project)
    foreign_host = create(:agent_host, organization: foreign_organization)
    foreign_ticket = create(:ticket, :agent_workable, organization: foreign_organization, project: foreign_project, with_agent_workflow: true)
    foreign_token = Agents::TicketQueues::Selection.issue(ticket: foreign_ticket, host: foreign_host)
    other = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-3", platform: "linux", arch: "amd64"
    ).value
    other_host_token = Agents::TicketQueues::Selection.issue(ticket:, host: other.fetch(:host))

    expect do
      post path, params: params.merge(selection_token: foreign_token), headers:, as: :json
      expect(response).to have_http_status(:not_found)

      post path, params: params.merge(selection_token: other_host_token), headers:, as: :json
      expect(response).to have_http_status(:not_found)
    end.not_to change(Agents::TicketQueueDeferral, :count)
  end

  it "rifiuta host_id diverso dall'identità bearer" do
    other_host = create(:agent_host, organization:)

    post path, params: params.merge(host_id: other_host.id), headers:, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-QUEUE-001")
    expect(Agents::TicketQueueDeferral).not_to exist
  end

  it "rivalida snapshot e lease prima del defer" do
    stale = selection_token
    ticket.update!(title: "Cambiato dopo la selezione")

    post path, params: params.merge(selection_token: stale), headers:, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-001")

    fresh = Agents::TicketQueues::Selection.issue(ticket:, host:)
    create(:agent_lease, organization:, ticket:, host:)
    post path, params: params.merge(selection_token: fresh), headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-004")
    expect(Agents::TicketQueueDeferral).not_to exist
  end
end
