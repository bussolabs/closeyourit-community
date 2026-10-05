# frozen_string_literal: true

require "rails_helper"

# CYRA-871 — «Ferma»: il CTO trattiene un rilascio che aspetta la produzione. Il codice è già su
# main, quindi il blocco tiene occupata la fila dei rilasci del repository (ProductionLock): nessun
# altro rilascio lo porterebbe in produzione di nascosto.
RSpec.describe Agents::Workflows::HoldProduction do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end

  before { organization.update!(cto:) }

  def in_attesa_della_produzione
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, "closer_production")
  end

  it "blocca la lavorazione prima della produzione e occupa la fila" do
    workflow = in_attesa_della_produzione
    altro = in_attesa_della_produzione

    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_ok
    expect(workflow.reload).to have_attributes(blocked_phase: "closer_production", blocked_kind: "held_by_person")
    expect(workflow.blocked_reason).to include(cto.name)
    expect(workflow.ready_execution_phase).to be_nil
    expect(Agents::Workflows::ProductionLock.holder(project:, except: altro)).to eq(workflow)
  end

  it "Riprova toglie il blocco e il rilascio torna in coda" do
    workflow = in_attesa_della_produzione
    described_class.call(workflow:, actor: cto)

    expect(Agents::Workflows::Unblock.call(workflow:, actor: cto)).to be_ok
    expect(workflow.reload.blocked_at).to be_nil
    expect(workflow.ready_execution_phase).to eq("closer_production")
  end

  it "lo può fare solo il CTO effettivo" do
    workflow = in_attesa_della_produzione
    altro = create(:account).tap { |account| create(:membership, :owner, account:, organization:) }

    result = described_class.call(workflow:, actor: altro)

    expect(result).to be_err
    expect(workflow.reload.blocked_at).to be_nil
  end

  it "rifiuta una lavorazione che non aspetta la produzione" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    workflow = pronta_per!(ticket.agent_workflow, "autopilot")

    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_err
    expect(result.error.code).to eq("R409-WORKFLOW-015")
    expect(workflow.reload.blocked_at).to be_nil
  end
end
