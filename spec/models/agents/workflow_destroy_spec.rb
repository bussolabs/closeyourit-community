# frozen_string_literal: true

require "rails_helper"

# CYRA-664 — cancellare un ticket su cui un agente ha lavorato falliva sempre, da CLI, da API e
# dalla pagina. Il vincolo che lo bloccava è voluto: `agents_plans.attempt_id` è a on_delete:
# :restrict perché un singolo tentativo non deve poter sparire portandosi via il proprio piano.
# Quando invece cade l'INTERO workflow, l'ordine va imposto a mano.
RSpec.describe Agents::Workflow, "distruzione a cascata" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:ticket) { create(:ticket, organization: organization, project: project, with_agent_workflow: true) }
  # La factory del ticket crea gia il proprio workflow: e il caso vero, un ticket che un
  # agente ha preso in carico.
  let(:workflow) { ticket.agent_workflow }
  let(:attempt) { create(:agent_attempt, workflow: workflow, phase: "planning") }

  def crea_piano(versione)
    Agents::Plan.create!(
      workflow: workflow, attempt: attempt, version: versione, contract_version: 1,
      technical_analysis: "analisi #{versione}", ticket_snapshot_digest: "d" * 64
    )
  end

  context "quando il lavoro dell'agente ha piano, chiarimenti e candidati" do
    before do
      piano = crea_piano(1)
      create(:agent_clarification, workflow: workflow, attempt: attempt)
      candidato = create(:agent_delivery_candidate, workflow: workflow, attempt: attempt)
      # I due riferimenti che il workflow tiene verso i propri figli: senza scioglierli
      # prima, distruggere piano e candidato viola le loro foreign key.
      workflow.update_columns(frozen_plan_id: piano.id, review_candidate_id: candidato.id)
    end

    it "il ticket si cancella" do
      expect { ticket.destroy! }.not_to raise_error
      expect(Ticketing::Ticket.where(id: ticket.id)).to be_empty
    end

    it "non lascia orfano niente del lavoro dell'agente" do
      workflow_id = workflow.id
      attempt_id = attempt.id
      ticket.destroy!

      expect(Agents::Workflow.where(id: workflow_id)).to be_empty
      expect(Agents::Attempt.where(id: attempt_id)).to be_empty
      expect(Agents::Plan.where(workflow_id: workflow_id)).to be_empty
      expect(Agents::Clarification.where(workflow_id: workflow_id)).to be_empty
      expect(Agents::DeliveryCandidate.where(workflow_id: workflow_id)).to be_empty
    end
  end

  it "un ticket che nessun agente ha mai toccato continua a cancellarsi" do
    pulito = create(:ticket, organization: organization, project: project)
    expect { pulito.destroy! }.not_to raise_error
  end
end
