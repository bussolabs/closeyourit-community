# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AgentTicketQueueClaims (automator)", type: :request do
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
  let(:params) do
    # Host-first (CYAU-91): il TTL autoritativo non è più il timeout dell'agente ma il PhaseProfile della
    # fase. La factory :agent è claude→command triage→fase triage, quindi il TTL fisso è 3600.
    { selection_token:, host_id: host.id, run_id: "run-42", ttl_seconds: 3600 }
  end
  # Host-first (CYAU-84): coda appiattita, senza agent_id nell'URL.
  let(:path) { "/api/v1/ticket_queue/claims" }

  before do
    host.update!(last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ], automator_version: "0.39.0",
                 runtimes: [ { "name" => "claude", "present" => true } ])
    # B.5 — scope per-host: la registrazione conia il service account dell'host senza progetti (fail-closed);
    # il claim lo ammette solo se quel SA vede il progetto, quindi qui gli concediamo la visibilità.
    create(:project_membership, account: host.service_account, project:)
  end

  it "acquisisce il ticket selezionato dalla coda come lease host-first puro" do
    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:created)
    # Host-first (CYAU-84): nessuno slug agent (agent = null); l'identità autoritativa è execution_phase +
    # profile_digest, che Deliver rivalida.
    expect(response.parsed_body.fetch("data")).to include(
      "ticket" => ticket.code, "host_id" => host.id, "run_id" => "run-42", "agent" => nil,
      "execution_phase" => "triage"
    )
    # Host-first (CYAU-91): la reservation è host+phase-scoped, Reserve non traccia più l'agente.
    expect(Agents::LimitReservation.sole).to have_attributes(
      project:, host:, estimated_cost: nil, outcome: "granted"
    )
  end

  # CYRA-285: insieme al lease l'host riceve QUANTO profonda dev'essere la rilettura incrociata della fase
  # che ha appena preso — prima di eseguirla, e senza poterla scegliere da sé. Il triage è una fase read:
  # si rilegge sul result strutturato, non sul diff.
  it "consegna col lease la profondità di rilettura decisa dal server per la fase" do
    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("data")).to include(
      "execution_phase" => "triage", "review_depth" => "result"
    )
  end

  it "rifiuta esplicitamente un TTL client diverso dal timeout autoritativo senza consumare limiti" do
    create(:agent_limit_policy, organization:, max_runtime_seconds: 60, max_parallel: 1)

    expect do
      post path, params: params.merge(ttl_seconds: 1.day.to_i), headers:, as: :json
    end.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include(
      "code" => "R409-QUEUE-005",
      "details" => { "requested_ttl_seconds" => 1.day.to_i, "expected_ttl_seconds" => 3600 }
    )
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
  end

  it "usa la scadenza della reservation autoritativa anche per il lease" do
    decision_time = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Limits::Clock).to receive(:current).and_return(decision_time)
    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time + 10.seconds)

    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:created)
    reservation = Agents::LimitReservation.sole
    expect(reservation.requested_ttl_seconds).to eq(3600)
    expect(reservation.expires_at).to eq(decision_time + 3600.seconds)
    expect(Agents::Lease.sole.expires_at).to eq(reservation.expires_at)
  end

  it "adotta e converte a host-first un lease legacy attivo dello stesso host e run" do
    decision_time = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Limits::Clock).to receive(:current).and_return(decision_time)
    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time)
    legacy = create(
      :agent_lease,
      organization:,
      ticket:,
      host:,
      run_id: params.fetch(:run_id),
      agent: "legacy-worker",
      expires_at: decision_time + 1.day
    )

    expect { post path, params:, headers:, as: :json }.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:ok)
    # Host-first (CYAU-84): l'adozione converte il lease legacy in host-first — pin execution_phase +
    # profile_digest, lo slug agent legacy è ritirato (agent = nil), scadenza autoritativa dalla reservation.
    expect(legacy.reload).to have_attributes(
      agent: nil,
      execution_phase: "triage",
      profile_digest: Agents::PhaseProfile.for("triage").digest,
      expires_at: Agents::LimitReservation.sole.expires_at,
      authoritative_ttl_seconds: 3600
    )
  end

  it "fallisce chiuso se la scadenza autoritativa della fase precede l'acquisizione del lease" do
    # TTL host-first fisso a 3600 (PhaseProfile): la reservation scade prima che l'Acquire prenda il lease.
    decision_time = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Limits::Clock).to receive(:current).and_return(decision_time)
    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time + 3601.seconds)

    expect do
      post path, params:, headers:, as: :json
    end.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-LEASE-004")
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
  end

  it "impedisce al renew legacy di riallungare il TTL di un lease autoritativo" do
    decision_time = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Limits::Clock).to receive(:current).and_return(decision_time)
    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time)
    post path, params:, headers:, as: :json
    original_expiry = Agents::Lease.sole.expires_at

    post "/api/v1/leases/#{ticket.code}/renew",
         params: params.except(:selection_token).merge(ticket: ticket.code, ttl_seconds: 1.day.to_i),
         headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include(
      "code" => "R409-LEASE-003",
      "details" => { "requested_ttl_seconds" => 1.day.to_i, "expected_ttl_seconds" => 3600 }
    )
    expect(Agents::Lease.sole.expires_at).to eq(original_expiry)

    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time + 20.seconds)
    post "/api/v1/leases/#{ticket.code}/renew",
         params: params.except(:selection_token).merge(ticket: ticket.code), headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(Agents::Lease.sole.expires_at).to eq(original_expiry)
  end

  it "accetta soltanto il TTL autoritativo della fase e rifiuta un valore adiacente" do
    # TTL host-first fisso a 3600 (PhaseProfile della fase triage): non più pilotato dal timeout dell'agente,
    # quindi l'unico TTL client accettato è 3600; un valore vicino (3599) è un mismatch senza consumare limiti.
    decision_time = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Limits::Clock).to receive(:current).and_return(decision_time)
    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time)

    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)
    expect(Agents::LimitReservation.sole.requested_ttl_seconds).to eq(3600)
    expect(Agents::Lease.sole.expires_at).to eq(decision_time + 3600.seconds)

    adjacent = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    post path,
         params: params.merge(
           selection_token: Agents::TicketQueues::Selection.issue(ticket: adjacent, host:),
           run_id: "boundary-adjacent", ttl_seconds: 3599
         ),
         headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-005")
    expect(Agents::LimitReservation.count).to eq(1)
  end

  it "mantiene idempotenti reservation e lease sul replay e rifiuta un TTL diverso" do
    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)

    expect do
      post path, params:, headers:, as: :json
    end.not_to change {
      [ Agents::LimitReservation.count, Agents::LimitUsage.count, Agents::Lease.count ]
    }

    expect(response).to have_http_status(:ok)

    post path, params: params.merge(ttl_seconds: 61), headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-005")
    expect(Agents::LimitReservation.count).to eq(1)
    expect(Agents::LimitUsage.sole.runs).to eq(1)
    expect(Agents::Lease.count).to eq(1)
  end

  it "applica max_runtime sul TTL autoritativo della fase ai confini 3600 e 3599" do
    # TTL host-first fisso a 3600: il confine max_runtime si pilota dalla policy, non dal timeout agente.
    boundary = create(:agent_limit_policy, organization:, max_runtime_seconds: 3600)
    other_ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)

    boundary.update!(max_runtime_seconds: 3599)
    post path,
         params: params.merge(
           selection_token: Agents::TicketQueues::Selection.issue(ticket: other_ticket, host:),
           run_id: "runtime-over"
         ),
         headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include(
      "code" => "R409-QUEUE-002", "details" => { "reason" => "max_runtime" }
    )
    expect(Agents::LimitReservation.order(:created_at).pluck(:requested_ttl_seconds, :outcome)).to eq(
      [ [ 3600, "granted" ], [ 3600, "denied" ] ]
    )
    expect(Agents::Lease.count).to eq(1)
  end

  it "libera max_parallel alla scadenza autoritativa della reservation" do
    create(:agent_limit_policy, organization:, max_parallel: 1)
    second_ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    second_token = Agents::TicketQueues::Selection.issue(ticket: second_ticket, host:)
    decision_time = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Limits::Clock).to receive(:current).and_return(decision_time)
    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time)

    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)

    allow(Agents::Leases::Clock).to receive(:current).and_return(decision_time + 20.seconds)
    post "/api/v1/leases/#{ticket.code}/renew",
         params: params.except(:selection_token).merge(ticket: ticket.code), headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(Agents::Lease.find_by!(ticket:).expires_at).to eq(decision_time + 3600.seconds)

    post path,
         params: params.merge(selection_token: second_token, run_id: "parallel-denied"),
         headers:, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "details", "reason")).to eq("max_parallel")

    allow(Agents::Limits::Clock).to receive(:current).and_return(decision_time + 3600.seconds)
    post path,
         params: params.merge(selection_token: second_token, run_id: "parallel-after-expiry"),
         headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(Agents::LimitReservation.pluck(:outcome)).to contain_exactly("granted", "denied", "granted")
    expect(Agents::Lease.count).to eq(2)
    expect(Agents::Lease.where("expires_at > ?", decision_time + 3600.seconds).count).to eq(1)
  end

  it "non trasforma weight in costo e fallisce chiuso quando il budget monetario richiede una stima" do
    create(:agent_limit_policy, organization:, max_daily_cost: 10)
    ticket.update!(weight: 8)

    expect do
      post path, params: params.merge(estimated_cost: 0), headers:, as: :json
    end.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-QUEUE-002")
    expect(Agents::LimitReservation.sole).to have_attributes(
      estimated_cost: nil, outcome: "denied", denial_reason: "estimated_cost_unavailable"
    )
    expect(Agents::LimitUsage.sole).to have_attributes(runs: 0, cost: 0)
  end

  it "usa soltanto il costo firmato e applica X-1, X e X+1 al budget" do
    create(:agent_limit_policy, organization:, max_daily_cost: 10)
    tickets = allow_n_plus_one { 3.times.map { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) } }
    costs = [ "9.0000", "1.0000", "0.0001" ]

    outcomes = allow_n_plus_one do
      tickets.zip(costs).map.with_index do |(candidate, cost), index|
        token = Agents::TicketQueues::Selection.issue(ticket: candidate, host:, estimated_cost: cost)
        post path,
             params: params.merge(selection_token: token, run_id: "run-#{index}", estimated_cost: 0),
             headers:, as: :json
        [ response.status, response.parsed_body.dig("error", "code") ]
      end
    end

    expect(outcomes).to eq([ [ 201, nil ], [ 201, nil ], [ 409, "R409-QUEUE-002" ] ])
    expect(Agents::LimitReservation.order(:created_at).pluck(:estimated_cost, :outcome)).to eq(
      [ [ BigDecimal("9"), "granted" ], [ BigDecimal("1"), "granted" ], [ BigDecimal("0.0001"), "denied" ] ]
    )
    expect(Agents::LimitUsage.sole.cost).to eq(BigDecimal("10"))
  end

  it "rivaluta i limiti quando lo stesso run_id viene usato per ticket differenti" do
    create(:agent_limit_policy, organization:, max_daily_runs: 1)
    other_ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)

    post path,
         params: params.merge(selection_token: Agents::TicketQueues::Selection.issue(ticket: other_ticket, host:)),
         headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error")).to include(
      "code" => "R409-QUEUE-002", "details" => { "reason" => "max_daily_runs" }
    )
    expect(Agents::LimitReservation.pluck(:outcome)).to contain_exactly("granted", "denied")
    expect(Agents::LimitUsage.sole.runs).to eq(1)
    expect(Agents::Lease.count).to eq(1)
  end

  it "rifiuta token mancante, alterato e scaduto senza creare lease" do
    expired = Agents::TicketQueues::Selection.issue(ticket:, host:, expires_in: 1.second)

    expect do
      post path, params: params.except(:selection_token), headers:, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      post path, params: params.merge(selection_token: "#{selection_token}alterato"), headers:, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      post path, params: params.merge(selection_token: 123), headers:, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      travel 2.seconds do
        post path, params: params.merge(selection_token: expired), headers:, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end
    end.not_to change(Agents::Lease, :count)

    expect(response.parsed_body.dig("error", "code")).to eq("R422-QUEUE-001")
  end

  it "rifiuta una selezione stale se il ticket cambia dopo l'emissione" do
    token = selection_token
    ticket.update!(title: "Titolo modificato dopo la selezione")

    expect { post path, params: params.merge(selection_token: token), headers:, as: :json }
      .not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-001")
  end

  it "rifiuta una selezione stale se cambia un'associazione dello snapshot" do
    token = selection_token
    create(:ticket_comment, organization:, ticket:, body: "Contesto aggiunto dopo il preflight")

    expect { post path, params: params.merge(selection_token: token), headers:, as: :json }
      .not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-001")
  end

  it "non rivela né reclama selezioni di un'altra organizzazione (BOLA)" do
    # Host-first (CYAU-84): niente agent_id nell'URL; l'anti-BOLA è il token host-bound — una selezione di
    # un'altra org/host non combacia con l'organization/host autenticato e cade fail-closed su R404-QUEUE-001.
    foreign_organization = create(:organization)
    foreign_project = create(:project, organization: foreign_organization)
    create(:github_repository, project: foreign_project)
    foreign_host = create(:agent_host, organization: foreign_organization)
    foreign_ticket = create(:ticket, :agent_workable, organization: foreign_organization, project: foreign_project, with_agent_workflow: true)
    token = Agents::TicketQueues::Selection.issue(ticket: foreign_ticket, host: foreign_host)

    expect do
      post path, params: params.merge(selection_token: token), headers:, as: :json
    end.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-QUEUE-001")
  end

  it "lega la selezione all'host: un altro host non può reclamare il token" do
    other = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-other", platform: "linux", arch: "amd64"
    ).value

    post path, params: params.merge(host_id: other.fetch(:host).id),
         headers: { "Authorization" => "Bearer #{other.fetch(:secret)}" }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-QUEUE-001")
    expect(Agents::Lease.count).to eq(0)
  end

  it "rifiuta un host_id diverso dall'identità del bearer" do
    other_host = create(:agent_host, organization:)

    post path, params: params.merge(host_id: other_host.id), headers:, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-LEASE-001")
    expect(Agents::Lease.count).to eq(0)
  end

  {
    "host_id assente" => { host_id: nil },
    "run_id troppo lungo" => { run_id: "x" * 256 },
    "ttl non numerico" => { ttl_seconds: "60" }
  }.each do |label, override|
    it "rifiuta #{label}" do
      invalid = params.merge(override)
      post path, params: invalid, headers:, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-LEASE-001")
      expect(Agents::Lease).not_to exist
    end
  end

  # B.5 — con lo scope per-host il gate non è più il target dell'agente ma la visibilità del service
  # account dell'host: se il progetto esce da quello scope tra preflight e claim, si rivalida fail-closed.
  it "rivalida un progetto uscito dallo scope dell'host tra preflight e claim" do
    token = selection_token
    Connections::ProjectMembership.where(account: host.service_account, project:).delete_all

    expect { post path, params: params.merge(selection_token: token), headers:, as: :json }
      .not_to change(Agents::Lease, :count)
    expect(response).to have_http_status(:conflict)
  end

  it "rivalida un repository cambiato" do
    token = selection_token
    repository.update!(full_name: "bussolabs/repository-spostato")

    expect { post path, params: params.merge(selection_token: token), headers:, as: :json }
      .not_to change(Agents::Lease, :count)
    expect(response).to have_http_status(:conflict)
  end

  it "rivalida un ticket diventato done" do
    token = selection_token
    ticket.update!(status: create(:ticket_status, :done, organization:))

    expect { post path, params: params.merge(selection_token: token), headers:, as: :json }
      .not_to change(Agents::Lease, :count)
    expect(response).to have_http_status(:conflict)
  end

  it "consente a un solo host di reclamare lo stesso ticket" do
    other = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-2", platform: "linux", arch: "amd64"
    ).value
    # Token host-bound: ogni host il proprio; entrambi emessi mentre il ticket è ancora in triage_queued.
    token_other = Agents::TicketQueues::Selection.issue(ticket:, host: other.fetch(:host))

    post path, params:, headers:, as: :json
    expect(response).to have_http_status(:created)

    post path,
         params: params.merge(selection_token: token_other, host_id: other.fetch(:host).id, run_id: "run-other"),
         headers: { "Authorization" => "Bearer #{other.fetch(:secret)}" }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(Agents::Lease.where(ticket:).count).to eq(1)
  end

  it "non reclama una selezione precedente quando esiste un defer attivo per la stessa fase" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    create(:agent_ticket_queue_deferral, organization:, ticket:, host:,
                                            created_at: now - 1.minute, retry_at: now + 1.minute)

    expect { post path, params:, headers:, as: :json }.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include(
      "code" => "R409-QUEUE-003",
      "details" => { "reason" => "temporary_failure", "retry_at" => (now + 1.minute).iso8601(3) }
    )
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
  end

  it "fa prevalere il defer attivo anche sul kill switch dei limiti" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    create(:agent_limit_policy, organization:, stop_dispatch: true)
    create(:agent_ticket_queue_deferral, organization:, ticket:, host:,
                                            created_at: now - 1.minute, retry_at: now + 1.minute)

    expect { post path, params:, headers:, as: :json }.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-003")
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
  end

  it "fa prevalere il defer attivo anche sul limite giornaliero negato" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    create(:agent_limit_policy, organization:, max_daily_runs: 0)
    create(:agent_ticket_queue_deferral, organization:, ticket:, host:,
                                            created_at: now - 1.minute, retry_at: now + 1.minute)

    expect { post path, params:, headers:, as: :json }.not_to change(Agents::Lease, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-003")
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
  end

  it "preserva il contratto legacy di POST /api/v1/leases" do
    post "/api/v1/leases",
         params: { ticket: ticket.code, host_id: host.id, run_id: "legacy", agent: "legacy", ttl_seconds: 60 },
         headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "agent")).to eq("legacy")
    expect(Agents::LimitReservation).not_to exist
  end
end
