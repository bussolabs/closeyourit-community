# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentLeaseSerializer do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:host) { create(:agent_host, organization:) }

  # Un lease per ticket (indice unico): ogni fase pinnata vuole il suo, tranne dove il ticket serve in chiaro.
  def lease_for(phase, on: create(:ticket, organization:, project:, with_agent_workflow: true))
    create(:agent_lease, organization:, ticket: on, host:, agent: nil, execution_phase: phase,
                         profile_digest: Agents::PhaseProfile.for(phase).digest)
  end

  it "espone identità del lease, ownership host+run e fase eseguibile pinnata" do
    json = JSON.parse(described_class.new(lease_for("triage", on: ticket)).serialize)

    expect(json).to include(
      "ticket" => ticket.code, "host_id" => host.id, "agent" => nil, "execution_phase" => "triage",
      "profile_digest" => Agents::PhaseProfile.for("triage").digest
    )
  end

  # CYRA-285: la profondità della rilettura incrociata viaggia col lease, così l'host sa cosa chiedere al
  # reviewer PRIMA di eseguire la fase — e la legge da noi invece di deciderla da sé.
  describe "profondità della rilettura incrociata dichiarata dal server" do
    it "chiede il solo result strutturato sulle fasi read" do
      %w[triage planner].each do |phase|
        json = JSON.parse(described_class.new(lease_for(phase)).serialize)
        expect(json).to include("execution_phase" => phase, "review_depth" => "result")
      end
    end

    it "chiede la rilettura del diff alla sola fase che scrive codice" do
      json = JSON.parse(described_class.new(lease_for("autopilot")).serialize)

      expect(json).to include("execution_phase" => "autopilot", "review_depth" => "diff")
    end

    # CYAU-176 — le due fasi che rilasciano scrivono nel repository ma non producono un diff da rileggere:
    # uniscono e marchiano, e a rilascio riuscito le modifiche sono già dentro il ramo principale.
    it "chiede il solo result alle due fasi che rilasciano" do
      %w[closer_staging closer_production].each do |phase|
        json = JSON.parse(described_class.new(lease_for(phase)).serialize)
        expect(json).to include("execution_phase" => phase, "review_depth" => "result")
      end
    end

    # Una presa in carico dichiarata da una persona via CLI (CYRA-293) non esegue nessuna fase: non c'è
    # una rilettura da chiedere, e il campo lo dice invece di inventare una profondità.
    it "resta nulla sul lease di un account, che non esegue fasi" do
      lease = create(:agent_lease, :held_by_account)

      json = JSON.parse(described_class.new(lease).serialize)

      expect(json).to include("execution_phase" => nil, "review_depth" => nil)
    end
  end
  # CYRA-621 — il numero di versione e il punto di codice li decide il server prima che la fase parta
  # e li consegna con l'incarico: la macchina li riceve e li esegue, non li sceglie più.
  describe "il numero di versione dichiarato dal server" do
    it "arriva col lease della fase che rilascia" do
      lease = lease_for("closer_staging")
      Agents::ReleaseAssignment.create!(
        workflow: lease.ticket.agent_workflow,
        github_repository: lease.ticket.project.github_repository || create(:github_repository, project: lease.ticket.project),
        execution_phase: "closer_staging", version: "v1.4.3-beta.1", baseline_tag: "v1.4.2"
      )

      json = JSON.parse(described_class.new(lease.reload).serialize)

      expect(json.dig("release", "version")).to eq("v1.4.3-beta.1")
      expect(json.dig("release", "sha")).to be_nil
    end

    it "porta anche il punto di codice sulla versione definitiva" do
      lease = lease_for("closer_production")
      Agents::ReleaseAssignment.create!(
        workflow: lease.ticket.agent_workflow,
        github_repository: lease.ticket.project.github_repository || create(:github_repository, project: lease.ticket.project),
        execution_phase: "closer_production", version: "v1.4.3", sha: "c" * 40, baseline_tag: "v1.4.2"
      )

      json = JSON.parse(described_class.new(lease.reload).serialize)

      expect(json["release"]).to eq("version" => "v1.4.3", "sha" => "c" * 40)
    end

    # Dove non c'è un rilascio da fare il campo è nullo: un numero su una fase che non pubblica
    # sarebbe un dato che chi legge crederebbe assegnato.
    it "resta nullo dove non c'è niente da rilasciare" do
      json = JSON.parse(described_class.new(lease_for("autopilot")).serialize)

      expect(json["release"]).to be_nil
    end
  end
end
