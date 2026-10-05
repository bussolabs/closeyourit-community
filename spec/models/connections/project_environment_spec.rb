# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::ProjectEnvironment, type: :model do
  it "dichiara un environment su un progetto della stessa org" do
    project = create(:project)
    env = create(:environment, organization: project.organization)
    expect(build(:project_environment, project:, environment: env)).to be_valid
  end

  it "rifiuta un environment di un'altra org (integrità tenant)" do
    project = create(:project)
    other_env = create(:environment, organization: create(:organization))
    expect(build(:project_environment, project:, environment: other_env)).not_to be_valid
  end

  it "rifiuta lo stesso environment dichiarato due volte sullo stesso progetto" do
    project = create(:project)
    env = create(:environment, organization: project.organization)
    create(:project_environment, project:, environment: env)
    expect(build(:project_environment, project:, environment: env)).not_to be_valid
  end

  it "guard tenant: non solleva quando project/environment sono assenti" do
    # Esercita il return del guard difensivo blank? in environment_matches_project_organization.
    expect { described_class.new.valid? }.not_to raise_error
  end

  describe "risoluzione capability (default ambiente + override tri-state)" do
    %i[servers uptime secrets].each do |cap|
      col = :"#{cap}_enabled"
      predicate = :"#{cap}_enabled?"

      context "flag #{cap}" do
        it "eredita il default ON dell'ambiente quando l'override è nil" do
          env = build(:environment, col => true)
          link = build(:project_environment, environment: env, col => nil)
          expect(link.public_send(predicate)).to be true
        end

        it "eredita il default OFF dell'ambiente quando l'override è nil" do
          env = build(:environment, col => false)
          link = build(:project_environment, environment: env, col => nil)
          expect(link.public_send(predicate)).to be false
        end

        it "l'override true forza ON anche se il default dell'ambiente è OFF" do
          env = build(:environment, col => false)
          link = build(:project_environment, environment: env, col => true)
          expect(link.public_send(predicate)).to be true
        end

        it "l'override false forza OFF anche se il default dell'ambiente è ON" do
          env = build(:environment, col => true)
          link = build(:project_environment, environment: env, col => false)
          expect(link.public_send(predicate)).to be false
        end
      end
    end

    # approval_required (CYRA-138, Fase 4 pezzo C1a) è la 4a capability, ma la colonna NON segue lo
    # schema "#{cap}_enabled" delle altre 3 — testata a parte per lo stesso motivo (predicato dedicato
    # #approval_required?, non derivabile per interpolazione da "approval").
    context "flag approval (colonna approval_required, predicato #approval_required?)" do
      it "eredita il default ON dell'ambiente quando l'override è nil" do
        env = build(:environment, approval_required: true)
        link = build(:project_environment, environment: env, approval_required: nil)
        expect(link.approval_required?).to be true
      end

      it "eredita il default OFF dell'ambiente quando l'override è nil" do
        env = build(:environment, approval_required: false)
        link = build(:project_environment, environment: env, approval_required: nil)
        expect(link.approval_required?).to be false
      end

      it "l'override true forza ON anche se il default dell'ambiente è OFF" do
        env = build(:environment, approval_required: false)
        link = build(:project_environment, environment: env, approval_required: true)
        expect(link.approval_required?).to be true
      end

      it "l'override false forza OFF anche se il default dell'ambiente è ON" do
        env = build(:environment, approval_required: true)
        link = build(:project_environment, environment: env, approval_required: false)
        expect(link.approval_required?).to be false
      end
    end
  end

  describe ".capability_overrides con la capability approval" do
    it "forma singola: { capability: 'approval', value: 'on' } → { approval_required: true }" do
      expect(described_class.capability_overrides(capability: "approval", value: "on"))
        .to eq(approval_required: true)
    end

    it "forma singola: value 'inherit' → { approval_required: nil }" do
      expect(described_class.capability_overrides(capability: "approval", value: "inherit"))
        .to eq(approval_required: nil)
    end

    it "forma multipla: approval convive con le altre capability nello stesso hash" do
      result = described_class.capability_overrides("approval" => "off", "servers" => "on")
      expect(result).to eq(approval_required: false, servers_enabled: true)
    end
  end
end
