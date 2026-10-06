# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Host, type: :model do
  it "riconosce Linux come unica piattaforma supportata senza invalidare lo storico" do
    linux = build(:agent_host, platform: "linux")
    historical = build(:agent_host, platform: "darwin")

    expect(linux).to be_supported_platform
    expect(historical).not_to be_supported_platform
    expect(historical).to be_valid
  end

  it "richiede fingerprint e metadati macchina essenziali" do
    host = build(:agent_host, fingerprint: "", hostname: "", platform: "", arch: "")

    expect(host).to be_invalid
    expect(host.errors.attribute_names).to include(:fingerprint, :hostname, :platform, :arch)
  end

  it "accetta un service account service e membro dell'org come identità (B.1)" do
    organization = create(:organization)
    service_account = Accounts::Service::Create.call(organization:, name: "SA host", handle: "sa-host-valid").value

    expect(build(:agent_host, organization:, service_account:)).to be_valid
  end

  it "accetta service_account nil (transizione: host storici senza identità)" do
    expect(build(:agent_host, service_account: nil)).to be_valid
  end

  it "rifiuta un account human come identità dell'host" do
    organization = create(:organization)
    host = build(:agent_host, organization:, service_account: create(:account))

    expect(host).to be_invalid
    expect(host.errors.attribute_names).to include(:service_account)
  end

  it "rifiuta un service account di un'altra organizzazione (non membro)" do
    organization = create(:organization)
    foreign_sa = Accounts::Service::Create.call(organization: create(:organization), name: "SA altra", handle: "sa-foreign").value
    host = build(:agent_host, organization:, service_account: foreign_sa)

    expect(host).to be_invalid
    expect(host.errors.attribute_names).to include(:service_account)
  end

  it "normalizza il fingerprint e delega l'unicità per organization al vincolo DB" do
    existing = create(:agent_host, fingerprint: " host-abc ")

    duplicate = build(:agent_host, organization: existing.organization, fingerprint: "HOST-ABC")
    other_tenant = build(:agent_host, fingerprint: "HOST-ABC")

    expect(existing.reload.fingerprint).to eq("host-abc")
    expect(described_class.validators_on(:fingerprint))
      .not_to include(an_instance_of(ActiveRecord::Validations::UniquenessValidator))
    expect(duplicate).to be_valid
    expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(other_tenant).to be_valid
  end

  it "supporta 0/1/N host per organization e distrugge le credenziali dipendenti" do
    organization = create(:organization)
    expect(organization.agent_hosts).to be_empty

    first = create(:agent_host, organization:)
    second = create(:agent_host, organization:)
    create(:agent_host_token, host: first)

    expect(organization.reload.agent_hosts).to contain_exactly(first, second)
    expect { first.destroy! }.to change(Agents::HostToken, :count).by(-1)
  end

  it "elimina lease e tombstone ma preserva reservation e idempotenza quando l'host viene eliminato" do
    organization = create(:organization)
    project = create(:project, organization:)
    ticket = create(:ticket, organization:, project:)
    host_sa = Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
    host = create(:agent_host, organization:, service_account: host_sa)
    create(:agent_limit_policy, organization:, max_parallel: 1)
    lease = create(:agent_lease, organization:, ticket:, host:)
    Agents::Leases::Tombstone.record!(lease:, released_at: Time.current)
    idempotency_key = SecureRandom.uuid
    reservation = Agents::Limits::Reserve.call(
      organization:, host:, project:, phase: "autopilot", idempotency_key:, estimated_cost: 0
    ).value.reservation

    expect { host.destroy! }
      .to change(Agents::Lease, :count).by(-1)
      .and change(Agents::Leases::Tombstone, :count).by(-1)
    expect(Agents::LimitReservation.count).to eq(1)
    expect(reservation.reload).to be_granted
    expect(reservation.host).to be_nil
    expect(Agents::LimitReservation.find_by!(organization:, idempotency_key:)).to eq(reservation)

    host_fk = ActiveRecord::Base.connection.foreign_keys(:agents_limit_reservations)
                                .find { |foreign_key| foreign_key.column == "host_id" }
    expect(host_fk.on_delete).to eq(:nullify)
    expect(Agents::LimitReservation.columns_hash.fetch("host_id").null).to be(true)

    replacement_sa = Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
    replacement = create(:agent_host, organization:, service_account: replacement_sa)
    replay = Agents::Limits::Reserve.call(
      organization:, host: replacement, project:, phase: "autopilot", idempotency_key:, estimated_cost: 0
    )
    second = Agents::Limits::Reserve.call(
      organization:, host: replacement, project:, phase: "autopilot",
      idempotency_key: SecureRandom.uuid, estimated_cost: 0
    )

    expect(replay).to be_err
    expect(replay.error.code).to eq("R409-AGENT-001")
    expect(second.value.reservation).to have_attributes(outcome: "denied", denial_reason: "max_parallel")
  end

  it "distingue host attivi e revocati" do
    active = create(:agent_host)
    revoked = create(:agent_host, :revoked, organization: active.organization)

    expect(described_class.active).to contain_exactly(active)
    expect(active.revoked?).to be(false)
    expect(revoked.revoked?).to be(true)
  end

  it "valida la forma persistita della telemetria anche fuori dall'endpoint ingest" do
    host = build(
      :agent_host,
      runtimes: {}, repositories: {}, active_runs: {}, running: -1, slots: 0,
      host_status: "unknown", heartbeat_expected_interval_minutes: 0, heartbeat_grace_minutes: -1
    )

    expect(host).to be_invalid
    expect(host.errors.attribute_names).to include(
      :runtimes, :repositories, :active_runs, :running, :slots, :host_status,
      :heartbeat_expected_interval_minutes, :heartbeat_grace_minutes
    )
  end

  it "rifiuta active run non strutturate come oggetti" do
    host = build(:agent_host, active_runs: [ "invalid" ])

    expect(host).to be_invalid
    expect(host.errors.attribute_names).to include(:active_runs)
  end

  # CYRA-450 — "fermo" (stale): l'host ha superato il suo intervallo (offline) E tace da oltre la soglia di
  # allarme. La soglia è il pavimento di grazia: un riavvio breve non allarma. stale ⟹ offline sempre.
  describe "#heartbeat_stale?" do
    let(:now) { Time.current }
    let(:after) { Agents::Constants::HOST_STALE_AFTER }

    def host(**attrs)
      build(:agent_host, heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1, **attrs)
    end

    it "un host online (battito recente) non è mai fermo" do
      expect(host(last_heartbeat_at: 30.seconds.ago).heartbeat_stale?(now:)).to be(false)
    end

    it "un host appena offline ma sotto la soglia non è ancora fermo (grazia anti-riavvio)" do
      expect(host(last_heartbeat_at: now - after + 1.minute).heartbeat_stale?(now:)).to be(false)
    end

    it "un host offline e silente oltre la soglia è fermo" do
      expect(host(last_heartbeat_at: now - after - 1.minute).heartbeat_stale?(now:)).to be(true)
    end

    it "un host mai battuto ma appena registrato non è fermo" do
      host = create(:agent_host, last_heartbeat_at: nil)
      expect(host.heartbeat_stale?(now:)).to be(false)
    end

    it "un host mai battuto e registrato da oltre la soglia è fermo" do
      host = create(:agent_host, last_heartbeat_at: nil)
      host.update_column(:created_at, now - after - 1.minute)
      expect(host.heartbeat_stale?(now:)).to be(true)
    end

    # Un host revocato è dismesso, non "fermo": non ci si aspetta che risponda, quindi niente allarme —
    # coerente col detector, che scorre solo gli host attivi.
    it "un host revocato non è mai fermo, anche se silente da giorni" do
      host = host(last_heartbeat_at: now - 4.days, revoked_at: now)
      expect(host.heartbeat_stale?(now:)).to be(false)
    end
  end

  # CYAU-227 — a machine with no choice of its own follows the organization's.
  describe "engine choice" do
    let(:organization) { create(:organization) }
    let(:host) { create(:agent_host, organization:) }

    it "follows the organization when the machine has no choice of its own" do
      create(:agent_automator_setting, organization:, work_engine: "codex", reviewer: "claude")

      expect(host).to be_follows_organization
      expect(host).to have_attributes(effective_work_engine: "codex", effective_reviewer: "claude")
    end

    it "keeps its own choice when the organization changes" do
      host.update!(work_engine: "claude", reviewer: "codex")
      create(:agent_automator_setting, organization:, work_engine: "codex", reviewer: "claude")

      expect(host.reload).not_to be_follows_organization
      expect(host).to have_attributes(effective_work_engine: "claude", effective_reviewer: "codex")
    end

    it "starts its own choice from the organization's when only one engine is set" do
      create(:agent_automator_setting, organization:, work_engine: "codex", reviewer: "claude")

      host.update!(reviewer: "codex")

      expect(host.reload).to have_attributes(work_engine: "codex", reviewer: "codex")
    end

    it "hands the review to the organization's worker when the work moves to the organization's reviewer" do
      create(:agent_automator_setting, organization:, work_engine: "claude", reviewer: "codex")

      host.update!(work_engine: "codex")

      expect(host.reload).to have_attributes(work_engine: "codex", reviewer: "claude")
    end

    it "keeps a single-engine choice when the work stays on the same engine" do
      create(:agent_automator_setting, organization:, work_engine: "claude", reviewer: "claude")

      host.update!(work_engine: "claude")

      expect(host.reload).to have_attributes(effective_work_engine: "claude", effective_reviewer: "claude")
    end

    # Saving the form a following machine is pre-filled with is not a choice.
    it "keeps following the organization when the engine saved is the one in force" do
      create(:agent_automator_setting, organization:, work_engine: "claude", reviewer: "codex")

      host.update!(reviewer: "codex")
      host.update!(work_engine: "claude")

      expect(host.reload).to be_follows_organization
    end

    # CYAU-228
    it "accepts OpenCode as reviewer but never as the engine that works" do
      create(:agent_automator_setting, organization:, opencode_model: "anthropic/claude-sonnet-4.5")
      host.update!(work_engine: "claude", reviewer: "opencode")
      expect(host.reload).to have_attributes(effective_work_engine: "claude", effective_reviewer: "opencode")

      expect(host.update(work_engine: "opencode")).to be(false)
    end

    it "refuses OpenCode as its reviewer while the organization has no OpenRouter model" do
      create(:agent_automator_setting, organization:, opencode_model: nil)

      expect(host.update(reviewer: "opencode")).to be(false)
      expect(host.errors).to include(:reviewer)
    end

    it "goes back to following the organization" do
      host.update!(work_engine: "codex", reviewer: "claude")

      host.update!(work_engine: nil, reviewer: nil)

      expect(host.reload).to be_follows_organization
    end
  end
end
