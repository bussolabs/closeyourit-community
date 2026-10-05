# frozen_string_literal: true

require "rails_helper"

# CYRA-729 — il gemello in blocco della catena delle fasi non aveva prove sue.
#
# `phase_vocabulary_spec` presidia le PAROLE (ogni fase ha un passaggio, i due gemelli dicono le
# stesse), non la CATENA: nessuno verificava che, dato lo stesso workflow, il gemello e il modello
# rispondano la stessa fase su ogni ramo. E la divergenza non si vede: un ramo che sbaglia produce
# una riga che nella lista si racconta diversa da come si racconta nella sua scheda, senza errori.
#
# Qui la parità è verificata ramo per ramo e passando dagli helper di batch veri — sono quelli che
# la coda delle approvazioni e l'elenco delle lavorazioni in volo usano davvero.
RSpec.describe Agents::Workflows::PhaseResolver do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account).tap { |account| create(:membership, account:, organization:) } }

  def workflow_con(**attributi)
    ticket = create(:ticket, organization:, project:, reporter: actor, reviewer: actor)
    create(:agent_workflow, ticket:, organization:, **attributi)
  end

  # La fase letta come la legge una LISTA: le phase bocciate arrivano dalla pluck in blocco, non da
  # una query per workflow. È il percorso di produzione, non una scorciatoia di prova.
  def fase_in_blocco(workflow)
    bocciate = described_class.failed_phases_by_workflow([ workflow.id ])[workflow.id]
    described_class.phase(workflow, bocciate)
  end

  def boccia!(workflow, phase)
    create(:agent_attempt, workflow:, organization:, phase:, status: :review_failed)
  end

  describe ".phase — parità con Agents::Workflow#phase, ramo per ramo" do
    # Ogni riga è un ramo della catena. La chiave è la fase attesa; il valore, gli attributi minimi
    # che ce la portano. L'ordine è quello della catena: chi sta sopra vince su chi sta sotto.
    catena = {
      "cancelled" => { cancelled_at: 1.hour.ago, completed_at: 1.hour.ago },
      "completed" => { completed_at: 1.hour.ago, closer_production_started_at: 2.hours.ago },
      "awaiting_production_proof" => { closer_production_started_at: 2.hours.ago,
                                       closer_production_completed_at: 1.hour.ago },
      "closer_production" => { closer_production_started_at: 1.hour.ago },
      "closer_production_queued" => { closer_staging_completed_at: 2.hours.ago,
                                      closer_staging_verified_at: 1.hour.ago },
      "verifying_staging" => { closer_staging_started_at: 2.hours.ago,
                               closer_staging_completed_at: 1.hour.ago },
      "closer_staging" => { closer_staging_started_at: 1.hour.ago },
      "closer_staging_queued" => { autopilot_approved_at: 1.hour.ago },
      "awaiting_autopilot_approval" => { autopilot_started_at: 3.hours.ago,
                                         autopilot_completed_at: 2.hours.ago,
                                         candidate_verified_at: 1.hour.ago },
      "verifying_candidate" => { autopilot_started_at: 2.hours.ago, autopilot_completed_at: 1.hour.ago },
      "autopilot" => { autopilot_started_at: 1.hour.ago },
      "autopilot_queued" => { approved_at: 1.hour.ago },
      "awaiting_approval" => { planned_at: 1.hour.ago },
      "planning" => { triaged_at: 1.hour.ago },
      "triaging" => { triage_started_at: 1.hour.ago },
      "triage_queued" => { triage_requested_at: 1.hour.ago },
      "inactive" => { triage_requested_at: nil }
    }

    catena.each do |attesa, attributi|
      it "dice #{attesa} come il modello" do
        workflow = workflow_con(**attributi)

        expect(workflow.phase).to eq(attesa)
        expect(fase_in_blocco(workflow)).to eq(attesa)
      end
    end

    # Il ramo che il gemello non può dedurre dai soli timestamp: serve la pluck delle bocciature.
    it "dice review_blocked su una fermata dichiarata dall'agente, come il modello" do
      workflow = workflow_con(autopilot_started_at: 1.hour.ago, blocked_at: 30.minutes.ago,
                              blocked_kind: "agent_blocked", blocked_phase: "autopilot")

      expect(workflow.phase).to eq("review_blocked")
      expect(fase_in_blocco(workflow)).to eq("review_blocked")
    end

    it "dice review_blocked su un closer attivo con un tentativo bocciato, come il modello" do
      workflow = workflow_con(closer_staging_started_at: 1.hour.ago)
      boccia!(workflow, "closer_staging")

      expect(workflow.phase).to eq("review_blocked")
      expect(fase_in_blocco(workflow)).to eq("review_blocked")
    end

    # La bocciatura su una fase GIÀ CHIUSA non ferma niente: è archivio, non un ostacolo.
    it "non legge come ferma una lavorazione bocciata su una fase poi conclusa, come il modello" do
      workflow = workflow_con(closer_staging_started_at: 3.hours.ago,
                              closer_staging_completed_at: 2.hours.ago,
                              closer_staging_verified_at: 1.hour.ago)
      boccia!(workflow, "closer_staging")

      expect(workflow.phase).to eq("closer_production_queued")
      expect(fase_in_blocco(workflow)).to eq("closer_production_queued")
    end

    it "dice review_blocked su una pianificazione bocciata e mai conclusa, come il modello" do
      workflow = workflow_con(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago)
      boccia!(workflow, "planner")

      expect(workflow.phase).to eq("review_blocked")
      expect(fase_in_blocco(workflow)).to eq("review_blocked")
    end

    # Un insieme non passato non deve far esplodere il gemello: le liste lo chiamano anche per
    # workflow che nella pluck non compaiono affatto (nessun tentativo bocciato).
    it "tratta un insieme di bocciature assente come nessuna bocciatura" do
      workflow = workflow_con(autopilot_started_at: 1.hour.ago)

      expect(described_class.phase(workflow, nil)).to eq("autopilot")
    end
  end

  # CYRA-796 — il gemello sul modello non esiste più: la fase closer attiva è un pezzo della catena,
  # e la catena sta in un posto solo. Restano le stesse quattro attese, su quello che è rimasto.
  describe ".active_closer_phase" do
    it "riconosce la produzione avviata e non consegnata" do
      workflow = workflow_con(closer_production_started_at: 1.hour.ago)

      expect(described_class.active_closer_phase(workflow)).to eq("closer_production")
    end

    # CYRA-624 — una produzione consegnata non è più attiva: aspetta la prova.
    it "non considera attiva una produzione già consegnata" do
      workflow = workflow_con(closer_production_started_at: 2.hours.ago,
                              closer_production_completed_at: 1.hour.ago)

      expect(described_class.active_closer_phase(workflow)).to be_nil
    end

    it "riconosce lo staging avviato e non consegnato" do
      workflow = workflow_con(closer_staging_started_at: 1.hour.ago)

      expect(described_class.active_closer_phase(workflow)).to eq("closer_staging")
    end

    it "non considera attivo nulla su una lavorazione che non ha ancora chiuso niente" do
      workflow = workflow_con(autopilot_started_at: 1.hour.ago)

      expect(described_class.active_closer_phase(workflow)).to be_nil
    end

    # La porta contro il ritorno della copia: finché il modello non ce l'ha, non c'è niente da
    # tenere allineato a mano.
    it "il modello non ne tiene una copia sua" do
      expect(Agents::Workflow.private_method_defined?(:active_closer_phase)).to be(false)
      expect(Agents::Workflow.method_defined?(:active_closer_phase)).to be(false)
    end
  end

  describe ".failed_phases_by_workflow" do
    it "raccoglie le sole fasi bocciate, una riga per workflow" do
      uno = workflow_con(autopilot_started_at: 1.hour.ago)
      due = workflow_con(autopilot_started_at: 1.hour.ago)
      boccia!(uno, "triage")
      boccia!(uno, "autopilot")
      create(:agent_attempt, workflow: due, organization:, phase: "triage", status: :running)

      raccolte = described_class.failed_phases_by_workflow([ uno.id, due.id ])

      expect(raccolte[uno.id]).to eq(Set["triage", "autopilot"])
      expect(raccolte).not_to have_key(due.id)
    end

    it "non interroga il database per una lista vuota" do
      expect(Agents::Attempt).not_to receive(:status_review_failed)

      expect(described_class.failed_phases_by_workflow([])).to eq({})
    end
  end

  describe ".open_phases_by_workflow" do
    it "raccoglie le sole fasi con un tentativo ancora aperto" do
      workflow = workflow_con(autopilot_started_at: 1.hour.ago)
      create(:agent_attempt, workflow:, organization:, phase: "autopilot", status: :running)
      create(:agent_attempt, workflow:, organization:, phase: "triage", status: :awaiting_review)
      boccia!(workflow, "closer_staging")

      aperte = described_class.open_phases_by_workflow([ workflow.id ])

      expect(aperte[workflow.id]).to eq(Set["autopilot", "triage"])
    end

    it "non interroga il database per una lista vuota" do
      expect(described_class.open_phases_by_workflow([])).to eq({})
    end
  end

  describe ".last_attempts_by_workflow_phase" do
    # Di una fase riprovata più volte si apre l'ultima: è quella che racconta come sta andando adesso.
    it "di ogni fase tiene il tentativo più recente" do
      workflow = workflow_con(autopilot_started_at: 3.hours.ago)
      vecchio = create(:agent_attempt, workflow:, organization:, phase: "autopilot",
                                       status: :review_failed, started_at: 3.hours.ago)
      recente = create(:agent_attempt, workflow:, organization:, phase: "autopilot",
                                       status: :running, started_at: 1.hour.ago)
      triage = create(:agent_attempt, workflow:, organization:, phase: "triage",
                                      status: :approved, started_at: 4.hours.ago)

      ultimi = described_class.last_attempts_by_workflow_phase([ workflow.id ])

      expect(ultimi[workflow.id]).to eq("autopilot" => recente.id, "triage" => triage.id)
      expect(ultimi[workflow.id]["autopilot"]).not_to eq(vecchio.id)
    end

    it "non interroga il database per una lista vuota" do
      expect(described_class.last_attempts_by_workflow_phase([])).to eq({})
    end
  end

  describe "i passaggi derivati" do
    # Le uscite si derivano per differenza: una parola nuova finisce da sé o fra le tappe o fra le
    # uscite, e non può restare fuori da tutte e due.
    it "le uscite sono tutto ciò che non è una tappa" do
      expect(described_class::EXITS).to eq(described_class::STAGES - described_class::STEPS)
      expect(described_class::EXITS).to contain_exactly("blocked", "cancelled")
    end

    # I segni «qui aspetta una persona» si derivano dalle fasi, non si scrivono a mano: quando è
    # caduto il terzo permesso sono passati da tre a due senza che nessuno toccasse un testo.
    it "le tappe che aspettano una persona derivano dalle fasi gatate" do
      attese = described_class::HUMAN_GATED_PHASES.map { |fase| described_class.stage(fase) }.uniq

      expect(described_class.waiting_steps).to eq(attese & described_class::STEPS)
      expect(described_class.waiting_steps).to contain_exactly("plan_to_approve", "to_review")
    end

    # `review_blocked` aspetta una persona ma la sua parola è un'uscita: non è una tappa del percorso.
    it "la fermata non compare fra le tappe che aspettano" do
      expect(described_class).to be_waiting_on_you("review_blocked")
      expect(described_class.waiting_steps).not_to include("blocked")
    end

    it "una fase di esecuzione sconosciuta non mette un segno sul passaggio sbagliato" do
      expect(described_class.step_of_execution_phase("fase_che_non_esiste")).to be_nil
      expect(described_class.step_of_execution_phase(nil)).to be_nil
    end
  end
end
