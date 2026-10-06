# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::Eligibility do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:github_repository) { create(:github_repository, project:) }
  # Host-first: input autoritativi = host + project + phase. Il profilo (PhaseProfile) fornisce il runtime;
  # phase "triage" → runtime "claude". Niente Agent/Command.
  let(:phase) { "triage" }
  # La visibilità sul progetto è del service account dell'HOST (ProjectScope host-only).
  let(:host_service_account) do
    create(:account, :service).tap { |account| create(:project_membership, account:, project:) }
  end
  let(:host) do
    create(:agent_host, organization:, service_account: host_service_account,
                        last_heartbeat_at: Time.current,
                        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1,
                        repositories: [ project.key ],
                        runtimes: [ { "name" => "claude", "present" => true, "version" => "1", "required" => true } ])
  end

  it "accetta soltanto l'intersezione completa" do
    expect(described_class.call(host:, project:, phase:)).to be_ok
  end

  # CYAU-100: la capacità stabile è separata dalla liveness del momento, così ApproveReview può chiedersi
  # «questa macchina POTREBBE servire la fase?» senza far dipendere la destinazione di un ticket dal fatto
  # che un host sia acceso adesso.
  describe ".capable? (capacità stabile, senza heartbeat né slot)" do
    it "è vero quando l'host ha scope, host-map e runtime della fase" do
      expect(described_class.capable?(host:, project:, phase:)).to be(true)
    end

    it "resta vero con l'host offline, mentre il claim reale nega" do
      host.update!(last_heartbeat_at: 1.day.ago)

      expect(described_class.capable?(host:, project:, phase:)).to be(true)
      expect(described_class.call(host:, project:, phase:)).to be_err
    end

    it "resta vero con tutti gli slot occupati, mentre il claim reale nega" do
      host.update!(running: host.slots)

      expect(described_class.capable?(host:, project:, phase:)).to be(true)
      expect(described_class.call(host:, project:, phase:)).to be_err
    end

    it "è falso se il progetto non è nella host-map" do
      host.update!(repositories: [])

      expect(described_class.capable?(host:, project:, phase:)).to be(false)
    end

    it "è falso se il runtime della fase non è presente" do
      host.update!(runtimes: [ { "name" => "claude", "present" => false, "required" => true } ])

      expect(described_class.capable?(host:, project:, phase:)).to be(false)
    end

    # CYRA-921 — the engine is the one the machine was told to work with, not the phase default.
    it "needs Codex on a machine set to work with Codex" do
      host.update!(work_engine: "codex")
      expect(described_class.capable?(host:, project:, phase:)).to be(false)

      host.update!(runtimes: [ { "name" => "codex", "present" => true, "version" => "1", "required" => true } ])
      expect(described_class.capable?(host:, project:, phase:)).to be(true)
    end

    # CYAU-228 — OpenCode only reviews; a machine that does not declare it takes no work.
    it "needs OpenCode, the organization's model and its OpenRouter key on a machine that reviews with OpenCode" do
      create(:agent_automator_setting, organization: host.organization, opencode_model: "anthropic/claude-sonnet-4.5")
      host.update!(reviewer: "opencode")
      create(:agent_openrouter_credential, organization: host.organization)
      expect(described_class.capable?(host:, project:, phase:)).to be(false)

      host.update!(runtimes: host.runtimes + [ { "name" => "opencode", "present" => true, "version" => "1" } ])
      expect(described_class.capable?(host: host.reload, project:, phase:)).to be(true)
    end

    it "keeps a machine that reviews with OpenCode out of work without the organization's OpenRouter key" do
      create(:agent_automator_setting, organization: host.organization, opencode_model: "anthropic/claude-sonnet-4.5")
      host.update!(reviewer: "opencode", runtimes: host.runtimes + [ { "name" => "opencode", "present" => true } ])

      expect(described_class.capable?(host: host.reload, project:, phase:)).to be(false)
    end

    it "keeps a machine that reviews with OpenCode out of work without a model" do
      # The forms refuse this state; the gate still holds if it is reached another way.
      host.update!(runtimes: host.runtimes + [ { "name" => "opencode", "present" => true } ])
      host.update_columns(work_engine: "claude", reviewer: "opencode")
      create(:agent_openrouter_credential, organization: host.organization)

      expect(described_class.capable?(host: host.reload, project:, phase:)).to be(false)
    end

    it "è falso su una fase sconosciuta (fail-closed)" do
      expect(described_class.capable?(host:, project:, phase: "inesistente")).to be(false)
    end
  end

  it "fallisce chiuso su una fase sconosciuta (nessun profilo)" do
    expect(described_class.call(host:, project:, phase: "inesistente").error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se il runtime della fase non è disponibile sull'host" do
    # PIVOT CYAU-87: ogni fase (incl. autopilot) gira con "claude" → un host senza "claude" presente non
    # può eseguire nessuna fase.
    host.update!(runtimes: [ { "name" => "claude", "present" => false, "version" => "1", "required" => true } ])
    expect(described_class.call(host:, project:, phase: "autopilot").error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se il service account dell'host non vede più il progetto" do
    Connections::ProjectMembership.where(account: host.service_account, project:).delete_all

    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se il repository non è risolvibile sull'host" do
    host.update!(repositories: [])

    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se il repository viene scollegato dal progetto" do
    github_repository.destroy!

    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se runtime o heartbeat non sono validi" do
    host.update!(last_heartbeat_at: 4.minutes.ago)

    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se l'installazione è stata revocata anche con heartbeat recente" do
    host.update!(revoked_at: Time.current)

    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso per un host storico non Linux" do
    host.update_column(:platform, "darwin")

    expect(described_class.capable?(host:, project:, phase:)).to be(false)
    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "rifiuta qualsiasi relazione cross-tenant" do
    foreign = create(:project)

    expect(described_class.call(host:, project: foreign, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se l'host non è ancora certificato" do
    host.update!(certified_at: nil)

    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "fallisce chiuso se l'host ha saturato gli slot di capacità" do
    host.update!(running: 1, slots: 1)

    expect(described_class.call(host:, project:, phase:).error.code).to eq("R403-AGENT-006")
  end

  it "accetta un host certificato con capacità residua" do
    host.update!(certified_at: Time.current, running: 1, slots: 2)

    expect(described_class.call(host:, project:, phase:)).to be_ok
  end
  # ── CYAU-178 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Da qui in avanti una consegna che scrive codice deve portare l'impronta del codice che l'host aveva
  # in mano, e un host più vecchio non sa comporla. Meglio che il ticket aspetti una macchina
  # aggiornata piuttosto che una macchina lavori un'ora e si veda rifiutare la consegna alla fine.
  describe "versione minima dell'automator per le fasi che scrivono codice" do
    def macchina(version)
      create(:agent_host, organization:, service_account: host_service_account, last_heartbeat_at: Time.current,
                          repositories: [ project.key ], automator_version: version,
                          runtimes: [ { "name" => "claude", "present" => true, "version" => "1", "required" => true } ])
    end

    let(:vecchio) { macchina("0.25.0") }
    let(:senza) { macchina(nil) }

    it "una macchina vecchia non prende le fasi che scrivono codice" do
      %w[autopilot closer_staging closer_production].each do |phase|
        expect(described_class.capable?(host: vecchio, project:, phase:)).to be(false), phase
      end
    end

    # Escludere anche le fasi che leggono fermerebbe lavoro che funziona benissimo: quelle non
    # consegnano codice e l'impronta non la devono portare.
    it "ma continua a prendere quelle che leggono soltanto" do
      %w[triage planner].each do |phase|
        expect(described_class.capable?(host: vecchio, project:, phase:)).to be(true), phase
      end
    end

    # Versione mai dichiarata: dedurre «sarà aggiornata» dal silenzio è il modo in cui il difetto
    # tornerebbe dentro.
    it "una macchina che non dice la propria versione non è idonea a scrivere" do
      expect(described_class.capable?(host: senza, project:, phase: "autopilot")).to be(false)
    end
  end
end
