# frozen_string_literal: true

require "rails_helper"

# CYRA-675 — «serve ancora, o è già fatto?».
#
# Non è un terzo modo di sbloccare: Unblock riapre la fase ferma e la fa riprovare com'era,
# RequestPlanChanges pretende un piano che esista e una motivazione. Qui non c'è niente da
# rimproverare a nessuno, e la lavorazione può non aver mai prodotto un piano.
RSpec.describe Agents::Workflows::Reassess do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end

  before { organization.update!(cto:) }

  describe "sul piano che aspetta un sì" do
    before do
      workflow.update!(triage_started_at: 2.hours.ago, triaged_at: 1.hour.ago, planned_at: 30.minutes.ago)
    end

    it "rimanda alla pianificazione" do
      result = described_class.call(workflow:, actor: cto)

      expect(result).to be_ok
      expect(workflow.reload.planned_at).to be_nil
      expect(workflow.phase).to eq("planning")
      expect(workflow.ready_execution_phase).to eq("planner")
    end

    # Il piano già scritto resta in archivio: `planned_at` è il marcatore di conclusione della fase,
    # non il piano. Il planner ne produrrà una versione nuova, e le due restano confrontabili.
    it "non cancella la versione già scritta del piano" do
      attempt = create(:agent_attempt, organization:, workflow:, phase: "planner")
      plan = Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [],
                                  definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")

      described_class.call(workflow:, actor: cto)

      expect(plan.reload).to be_persisted
      expect(workflow.reload.plans).to include(plan)
    end

    it "solo il CTO effettivo può chiederla" do
      altro = create(:account).tap { |account| create(:membership, account:, organization:) }

      result = described_class.call(workflow:, actor: altro)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-WORKFLOW-001")
      expect(workflow.reload.planned_at).to be_present
    end
  end

  describe "su una lavorazione ferma prima del piano" do
    # Ferma sul TRIAGE: `triaged_at` è nil e azzerare la pianificazione non basta — il claim ha già
    # scritto `triage_started_at`, e senza riaprire la fase la coda continuerebbe a saltarla.
    it "riapre la fase interrotta e toglie il blocco" do
      workflow.update!(triage_started_at: 2.hours.ago,
                       blocked_at: Time.current, blocked_phase: "triage", blocked_kind: "attempt_limit",
                       blocked_reason: "La revisione ha bocciato triage 2 volte su 2")
      create(:agent_attempt, workflow:, organization:, phase: "triage", status: :review_failed)

      result = described_class.call(workflow:, actor: cto)

      expect(result).to be_ok
      expect(workflow.reload.blocked_at).to be_nil
      expect(workflow.triage_started_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("triage")
    end

    # Il budget delle revisioni riparte insieme al blocco tolto: chi rivaluta senza farlo ripartire
    # concederebbe un solo tentativo invece dei due dichiarati (gli attempt bocciati sono audit
    # immutabile e restano a contare per sempre).
    it "fa ripartire il budget delle revisioni" do
      workflow.update!(triage_started_at: 2.hours.ago, triaged_at: 1.hour.ago, review_budget_from: 3.days.ago,
                       blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit",
                       blocked_reason: "tetto tentativi")
      create(:agent_attempt, workflow:, organization:, phase: "planner", status: :review_failed)

      described_class.call(workflow:, actor: cto)

      expect(workflow.reload.review_budget_from).to be > 1.minute.ago
    end

    # Una lavorazione mai partita si rivaluta lo stesso: è il caso di un ticket vecchio rimasto in
    # fondo alla coda, dove un piano non c'è mai stato.
    it "vale anche dove un piano non è mai esistito" do
      result = described_class.call(workflow:, actor: cto)

      expect(result).to be_ok
      expect(workflow.reload.phase).to eq("triage_queued")
    end
  end

  describe "dove non si rivaluta più" do
    # Il gate è del dominio e si rilegge sotto lock: fra la pagina aperta e il click la lavorazione
    # può essere andata avanti, e azzerare `approved_at` su una macchina che sta già scrivendo codice
    # lascerebbe uno stato che nessuno ha voluto.
    it "rifiuta quando il codice lo sta già scrivendo la macchina" do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 90.minutes.ago,
                       approved_at: 1.hour.ago, autopilot_started_at: 30.minutes.ago)

      result = described_class.call(workflow:, actor: cto)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-WORKFLOW-014")
      expect(workflow.reload.approved_at).to be_present
      expect(workflow.autopilot_started_at).to be_present
    end

    it "rifiuta su una lavorazione annullata" do
      workflow.update!(cancelled_at: Time.current, cancellation_reason: "non serve più")

      result = described_class.call(workflow:, actor: cto)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-WORKFLOW-001")
    end

    it "rifiuta su un ticket già chiuso" do
      ticket.update!(status: create(:ticket_status, :done, organization:))

      result = described_class.call(workflow:, actor: cto)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-WORKFLOW-013")
    end
  end
end
