# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Attempt, type: :model do
  describe "identità di esecuzione host-first" do
    let(:organization) { create(:organization) }
    let(:workflow) { create(:agent_workflow, organization:) }
    let(:host) { create(:agent_host, organization:) }
    let(:service_account) do
      create(:account, :service).tap { |account| create(:membership, account:, organization:) }
    end

    def host_first_attempt(**overrides)
      build(:agent_attempt, workflow:, organization:, host:, service_account:,
                            skill_key: "/closeyourit-triage", runtime: "claude", phase: "triage", **overrides)
    end

    it "è valido con service_account + skill_key" do
      expect(host_first_attempt).to be_valid
    end

    it "persiste e resta leggibile" do
      attempt = host_first_attempt(skill_key: "/closeyourit-autopilot", runtime: "codex", phase: "autopilot",
                                   sandbox: "workspace-write", allowed_tools: [], ttl: 3600)
      attempt.save!
      reloaded = described_class.find(attempt.id)

      expect(reloaded.skill_key).to eq("/closeyourit-autopilot")
      expect(reloaded.service_account).to eq(service_account)
    end

    it "rifiuta un service_account di un'altra organizzazione" do
      foreign = create(:account, :service).tap { |a| create(:membership, account: a, organization: create(:organization)) }
      attempt = host_first_attempt(service_account: foreign)

      expect(attempt).to be_invalid
      expect(attempt.errors[:service_account]).to be_present
    end

    it "rifiuta un service_account che non è un account di servizio" do
      human = create(:account).tap { |account| create(:membership, account:, organization:) }
      attempt = host_first_attempt(service_account: human)

      expect(attempt).to be_invalid
      expect(attempt.errors[:service_account]).to be_present
    end
  end

  describe "identità di esecuzione obbligatoria" do
    it "rifiuta un attempt senza service_account" do
      attempt = build(:agent_attempt, service_account: nil)

      expect(attempt).to be_invalid
      expect(attempt.errors[:base]).to be_present
    end

    it "rifiuta un attempt senza skill_key" do
      attempt = build(:agent_attempt, skill_key: nil)

      expect(attempt).to be_invalid
      expect(attempt.errors[:base]).to be_present
    end

    it "richiede sempre workflow e host" do
      attempt = build(:agent_attempt)
      attempt.assign_attributes(workflow: nil, host: nil)

      expect(attempt).to be_invalid
      expect(attempt.errors.attribute_names).to include(:workflow, :host)
    end
  end

  describe "execution profile immutabile" do
    let(:organization) { create(:organization) }
    let(:workflow) { create(:agent_workflow, organization:) }
    let(:host) { create(:agent_host, organization:) }
    let(:service_account) do
      create(:account, :service).tap { |account| create(:membership, account:, organization:) }
    end

    def host_first_attempt
      build(:agent_attempt, workflow:, organization:, host:, service_account:,
                            skill_key: "/closeyourit-triage", allowed_tools: %w[Read Glob Grep],
                            ttl: 3600, phase: "triage", runtime: "claude").tap(&:save!)
    end

    it "solleva ReadonlyAttributeError su ogni modifica del profilo dopo la creazione" do
      attempt = host_first_attempt

      expect { attempt.update!(skill_key: "/closeyourit-autopilot") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { host_first_attempt.update!(allowed_tools: [ "Bash" ]) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(described_class.find(attempt.id).skill_key).to eq("/closeyourit-triage")
    end

    it "lascia mutare i campi non-profilo (es. status)" do
      attempt = host_first_attempt

      attempt.update!(status: :awaiting_review)

      expect(described_class.find(attempt.id).status).to eq("awaiting_review")
    end

    it "congela anche host, fase e runtime dell'esecuzione" do
      expect { host_first_attempt.update!(phase: "autopilot") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { host_first_attempt.update!(runtime: "codex") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { host_first_attempt.update!(host: create(:agent_host, organization:)) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end
  end

  describe "audit immutabile e tenant integrity (invariati)" do
    it "non è modificabile dopo un esito terminale" do
      attempt = create(:agent_attempt, status: :approved)

      expect { attempt.update!(result: { "changed" => true }) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "rifiuta riferimenti di tenant diversi" do
      attempt = build(:agent_attempt)
      attempt.host = create(:agent_host)

      expect(attempt).to be_invalid
      expect(attempt.errors[:organization]).to be_present
    end
  end

  describe "colonne legacy senza vincolo (la rimozione dei typed-agent non distrugge l'audit)" do
    # Prima le FK erano ON DELETE SET NULL, così cancellare un agente svuotava il puntatore invece di
    # portarsi via il tentativo. Da CYRA-278 il catalogo non esiste più come tabella: il vincolo è
    # caduto con lei, la colonna no — gli attempt storici restano leggibili esattamente come prima.
    %w[agent_id command_id instruction_id run_id].each do |column|
      it "conserva #{column} senza vincolo verso il catalogo sparito" do
        connection = ActiveRecord::Base.connection

        expect(connection.column_exists?("agents_attempts", column)).to be(true)
        expect(connection.foreign_keys("agents_attempts").map(&:column)).not_to include(column)
      end
    end
  end

  describe "FK host-first ON DELETE RESTRICT (l'identità audit dell'host non è distruttibile)" do
    # host_id e service_account_id sono l'IDENTITÀ di esecuzione host-first, non riferimenti legacy
    # rimovibili: come host_id, il service_account non va mai nullificato (nullify romperebbe il XOR
    # host-first, lasciando un attempt con skill_key ma senza service_account = record malformato).
    %w[host_id service_account_id].each do |column|
      it "usa on_delete restrict per #{column}" do
        fk = ActiveRecord::Base.connection.foreign_keys("agents_attempts").find { |f| f.column == column }

        expect(fk.on_delete).to eq(:restrict)
      end
    end
  end
end
