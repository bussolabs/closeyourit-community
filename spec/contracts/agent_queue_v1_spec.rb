# frozen_string_literal: true

require "rails_helper"
require "digest"
require "json_schemer"

# Contract host-first della coda agenti (CYAU-94/84). Verifica lo snapshot vendorizzato
# (checksum-pin, gemello di ingest_v1_spec) e che gli endpoint FLAT host-scoped producano il wire richiesto
# dai `required` dello schema canonico (Draft 2020-12 in docs). CYAU-84 ha appiattito le route (nessun
# agent_id nell'URL): sono cambiati SOLO i path dei golden HTTP case, non i corpi.
RSpec.describe "Agent queue contract v1", type: :request do
  # Scoped come let (non costanti top-level): evita la collisione globale con `CONTRACT_ROOT`/`CONTRACT` di
  # ingest_v1_spec, che nella suite completa sovrascriverebbero questi path e farebbero leggere lo schema sbagliato.
  let(:contract_root) { Rails.root.join("contracts/agent-queue") }
  let(:contract) { contract_root.join("v1") }

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
  # Host-first (CYAU-84): coda appiattita, senza agent_id nell'URL.
  let(:claim_path) { "/api/v1/ticket_queue/claims" }
  let(:next_path) { "/api/v1/ticket_queue" }
  let(:deferral_path) { "/api/v1/ticket_queue/deferrals" }

  before do
    host.update!(last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ], automator_version: "0.39.0",
                 runtimes: [ { "name" => "claude", "present" => true } ])
    create(:project_membership, account: host.service_account, project:)
  end

  def contract_schema
    @contract_schema ||= JSON.parse(contract.join("schema.json").read)
  end

  # Gate di contratto REALE (P2, review Codex): la risposta live dell'endpoint deve validare contro il $def
  # pinnato dello schema canonico (Draft 2020-12), non solo esporne le chiavi — così un attempt_id nullo, un
  # expires_at malformato o un valore annidato invalido rompono il test invece di passare inosservati.
  def schema_errors(definition, document)
    contract_errors(contract_schema, definition, document)
  end

  it "corrisponde allo snapshot canonico bloccato e a tutti i checksum" do
    lock = JSON.parse(contract_root.join("LOCK.json").read)
    sums = contract.join("SHA256SUMS").read
    expect(Digest::SHA256.hexdigest(sums)).to eq(lock.fetch("sha256sums"))

    sums.each_line do |line|
      expected, relative = line.strip.split("  ./", 2)
      expect(Digest::SHA256.file(contract.join(relative)).hexdigest).to eq(expected), relative
    end
  end

  # Il wire host-first porta solo execution_phase + profile_digest, mai il profilo: server e automator ne tengono
  # ciascuno una copia (Agents::PhaseProfile / twin TS) e la fixture è l'accordo cross-consumer sul digest. Qui il
  # lato server: ogni digest del PhaseProfile deve combaciare con la fixture pinnata (l'automator verifica il proprio
  # twin contro la stessa fixture — un drift tra i due lati rompe la parità, oltre a R409-LEASE-005 a runtime).
  it "il profile_digest di ogni fase combacia col PhaseProfile server (parità twin cross-repo)" do
    fixture = JSON.parse(contract.join("fixtures/valid/phase_profiles.json").read)
    expect(fixture.keys).to match_array(Agents::PhaseProfile::PHASES)
    Agents::PhaseProfile::PHASES.each do |phase|
      expect(fixture.fetch(phase)).to eq(Agents::PhaseProfile.for(phase).digest), phase
    end
  end

  it "il claim host-first produce il lease host-bound del contratto" do
    post claim_path,
         params: { selection_token:, host_id: host.id, run_id: "run-42", ttl_seconds: 3600 },
         headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(schema_errors("claim_response", response.parsed_body)).to be_empty
    data = response.parsed_body.fetch("data")
    expect(data).to include(
      "ticket" => ticket.code, "host_id" => host.id, "run_id" => "run-42", "execution_phase" => "triage"
    )
    expect(data.fetch("profile_digest")).to match(/\A[0-9a-f]{64}\z/)
  end

  # CYRA-588 — la presa in carico atomica è un endpoint NUOVO (il bundle canonico vive in closeyourit-docs
  # e lo documenterà lì), ma non deve inventare un wire proprio: `data` resta il lease pinnato del claim,
  # con in più il candidato — così un client che già legge il claim legge anche questa risposta.
  it "il claim atomico riusa il wire del lease pinnato e vi aggiunge il candidato" do
    ticket # forza la creazione: il candidato dev'esistere perché la coda lo consegni

    post "/api/v1/ticket_queue/next_claim",
         params: { project_key: project.key, host_id: host.id, run_id: "run-42" },
         headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(schema_errors("claim_response", response.parsed_body)).to be_empty
    data = response.parsed_body.fetch("data")
    expect(data).to include("ticket" => ticket.code, "host_id" => host.id, "execution_phase" => "triage")
    expect(data.dig("candidate", "workflow")).to include("execution_phase" => "triage")
  end

  it "next serve il candidate del contratto con il selection token opaco" do
    ticket # forza la creazione: il candidato dev'esistere perché la coda lo ritorni

    get next_path, params: { project_key: project.key }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(schema_errors("next_candidate_response", response.parsed_body)).to be_empty
    data = response.parsed_body.fetch("data")
    expect(data).to include("code" => ticket.code)
    expect(data.fetch("selection_token")).to be_a(String).and(be_present)
    expect(data.fetch("estimated_cost")).to be_nil
  end

  it "next ritorna la coda vuota del contratto quando non c'è candidato" do
    # Nessun ticket creato (il let :ticket resta lazy e non referenziato) → coda vuota.
    get next_path, params: { project_key: project.key }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(schema_errors("next_empty_response", response.parsed_body)).to be_empty
    expect(response.parsed_body).to eq("data" => nil)
  end

  it "il deferral host+fase produce la riga del contratto" do
    post deferral_path,
         params: { selection_token:, host_id: host.id, reason: "temporary_failure" },
         headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(schema_errors("deferral_response", response.parsed_body)).to be_empty
    data = response.parsed_body.fetch("data")
    expect(data).to include(
      "ticket" => ticket.code, "host_id" => host.id, "execution_phase" => "triage",
      "reason" => "temporary_failure", "replayed" => false
    )
  end

  it "espone la tassonomia di errore del claim del contratto" do
    # TTL diverso dall'autoritativo → R409-QUEUE-005 con details.
    post claim_path,
         params: { selection_token:, host_id: host.id, run_id: "run-42", ttl_seconds: 1.day.to_i },
         headers:, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-QUEUE-005")
    expect(response.parsed_body.dig("error", "details")).to include("expected_ttl_seconds" => 3600)

    # Token opaco assente/alterato → R422-QUEUE-001.
    post claim_path,
         params: { selection_token: "not-a-valid-token", host_id: host.id, run_id: "run-42", ttl_seconds: 3600 },
         headers:, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-QUEUE-001")

    # host_id del corpo diverso dall'Agent Host autenticato → R403-LEASE-001.
    post claim_path,
         params: { selection_token:, host_id: SecureRandom.uuid, run_id: "run-42", ttl_seconds: 3600 },
         headers:, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-LEASE-001")
  end

  it "applica la matrice bearer del contratto: 401 senza credenziale, 401 con token org, 404 anti-BOLA host-bound" do
    org_token = Agents::Tokens::Issue.call(organization:, name: "automator").value.fetch(:secret)

    # 401 — nessuna credenziale.
    get next_path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-AGENT-001")

    # 401 — token org cyi_a_ (solo bootstrap host): gli endpoint della coda esigono un Agent Host cyi_ah_.
    get next_path, headers: { "Authorization" => "Bearer #{org_token}" }
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-AGENT-001")

    # Host-first (CYAU-84): niente agent_id nell'URL → l'anti-BOLA è il token host-bound. Una selezione di
    # un'altra org presentata a questo host non risolve: fail-closed 404 `R404-QUEUE-001` su claim e deferral.
    other_org = create(:organization)
    other_project = create(:project, organization: other_org)
    create(:github_repository, project: other_project)
    other_host = create(:agent_host, organization: other_org)
    other_ticket = create(:ticket, organization: other_org, project: other_project, with_agent_workflow: true)
    foreign_token = Agents::TicketQueues::Selection.issue(ticket: other_ticket, host: other_host)

    post claim_path,
         params: { selection_token: foreign_token, host_id: host.id, run_id: "run-42", ttl_seconds: 3600 },
         headers:, as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-QUEUE-001")

    post deferral_path,
         params: { selection_token: foreign_token, host_id: host.id, reason: "temporary_failure" }, headers:, as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-QUEUE-001")
  end

  # CYRA-638 — le due prove che rendono osservabile la differenza fra le due semantiche. Lo schema
  # dichiara `pattern` in ECMA-262, dove `^` e `$` legano l'INTERA stringa; con la semantica di casa
  # sono ancore di riga, quindi un valore giusto seguito da un a capo e da qualunque altro testo passa
  # per buono. Finché questo contratto descrive solo cio' che il server manda fuori il danno non c'e';
  # il giorno che diventasse anche una barriera in ingresso, il controllo resterebbe verde mentre il
  # sistema si comporta in un altro modo — e nessuno andrebbe a guardare, perche' il verde c'e'.
  it "giudica i pattern con le regole che il contratto dichiara, non con quelle di casa" do
    digest = "a" * 64
    expect(schema_errors("sha256", digest)).to be_empty
    expect(schema_errors("sha256", "#{digest}\nquesto non e' un digest")).not_to be_empty

    expect(schema_errors("error", { "code" => "R404-QUEUE-001", "message" => "non trovato" })).to be_empty
    expect(
      schema_errors("error", { "code" => "R404-QUEUE-001\nR200-TUTTO-BENE", "message" => "non trovato" })
    ).not_to be_empty
  end
end
