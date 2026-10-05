# frozen_string_literal: true

require "rails_helper"

# CYRA-279 — rendimento storico di un host. Tutto deriva dagli attempt TERMINALI (audit immutabile)
# e dai timestamp del workflow: nessuna colonna nuova, nessuno stato duplicato.
RSpec.describe Agents::Hosts::Performance do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }

  # Un attempt concluso dell'host: `seconds` è la durata, `age` quanto è vecchio (per il filtro periodo).
  def concluded(phase: "triage", status: :approved, seconds: 60, age: 1.hour, workflow: nil)
    started = age.ago
    create(:agent_attempt, organization:, host:, phase:, status:,
                           workflow: workflow || create(:agent_workflow, organization:),
                           started_at: started, finished_at: started + seconds)
  end

  describe "perimetro" do
    it "conta solo gli attempt di QUESTO host" do
      other = create(:agent_host, organization:)
      concluded
      create(:agent_attempt, organization:, host: other, status: :approved,
                             workflow: create(:agent_workflow, organization:),
                             started_at: 1.hour.ago, finished_at: 30.minutes.ago)

      expect(described_class.call(host:).attempts_count).to eq(1)
    end

    it "esclude gli attempt non terminali: un lavoro in corso non è un esito" do
      concluded
      create(:agent_attempt, organization:, host:, status: :running,
                             workflow: create(:agent_workflow, organization:), started_at: 5.minutes.ago)
      create(:agent_attempt, organization:, host:, status: :awaiting_review,
                             workflow: create(:agent_workflow, organization:), started_at: 5.minutes.ago)

      expect(described_class.call(host:).attempts_count).to eq(1)
    end

    it "filtra sul periodo scelto e con `all` prende tutta la storia" do
      concluded(age: 2.days)
      concluded(age: 45.days)

      expect(described_class.call(host:, range: "7d").attempts_count).to eq(1)
      expect(described_class.call(host:, range: "30d").attempts_count).to eq(1)
      expect(described_class.call(host:, range: "90d").attempts_count).to eq(2)
      expect(described_class.call(host:, range: "all").attempts_count).to eq(2)
    end

    it "un range sconosciuto ricade sul default invece di sollevare" do
      concluded(age: 45.days)

      expect(described_class.call(host:, range: "pippo").attempts_count).to eq(0)
    end
  end

  describe "esiti" do
    before do
      concluded(status: :approved)
      concluded(status: :approved)
      concluded(status: :rejected)
      concluded(status: :review_failed)
      concluded(status: :failed)
      concluded(status: :stale)
      concluded(status: :cancelled)
      concluded(status: :cancelled)
    end

    it "raggruppa gli otto stati nelle quattro categorie che si leggono" do
      outcomes = described_class.call(host:).outcomes

      expect(outcomes.approved).to eq(2)
      expect(outcomes.rejected).to eq(2)      # rejected + review_failed
      expect(outcomes.failed).to eq(1)
      expect(outcomes.interrupted).to eq(3)   # stale + cancelled
      expect(outcomes.total).to eq(8)
    end

    it "le quattro percentuali sommano a cento" do
      outcomes = described_class.call(host:).outcomes
      sum = outcomes.approved_pct + outcomes.rejected_pct + outcomes.failed_pct + outcomes.interrupted_pct

      expect(sum).to be_within(0.1).of(100)
      expect(outcomes.rejected_pct).to eq(25.0)
    end
  end

  describe "ticket lavorati" do
    it "conta le lavorazioni distinte, non i tentativi" do
      workflow = create(:agent_workflow, organization:)
      concluded(workflow:, phase: "triage")
      concluded(workflow:, phase: "planner")
      concluded

      report = described_class.call(host:)

      expect(report.attempts_count).to eq(3)
      expect(report.tickets_count).to eq(2)
    end
  end

  describe "tempo dell'host" do
    it "somma le durate per ticket, poi ne fa media e mediana" do
      first = create(:agent_workflow, organization:)
      concluded(workflow: first, phase: "triage", seconds: 100)
      concluded(workflow: first, phase: "planner", seconds: 200)   # ticket da 300s
      concluded(seconds: 500)                                      # ticket da 500s

      report = described_class.call(host:)

      expect(report.host_seconds_avg).to eq(400)
      expect(report.host_seconds_median).to eq(400) # mediana di [300, 500] su campione pari
    end

    it "senza attempt conclusi non inventa uno zero" do
      expect(described_class.call(host:).host_seconds_avg).to be_nil
    end
  end

  describe "tempo di lavorazione del ticket" do
    it "misura dalla richiesta di triage alla chiusura, sui soli workflow completati" do
      done = create(:agent_workflow, organization:, triage_requested_at: 10.hours.ago,
                                     completed_at: 8.hours.ago)
      concluded(workflow: done)
      concluded(workflow: create(:agent_workflow, organization:, completed_at: nil))

      expect(described_class.call(host:).workflow_seconds_avg).to be_within(1).of(2.hours.to_i)
    end

    it "è nil se nessuna lavorazione dell'host è mai arrivata in fondo" do
      concluded

      expect(described_class.call(host:).workflow_seconds_avg).to be_nil
    end

    # CYRA-499 — la misura esiste solo per le lavorazioni CHIUSE: quante siano è parte del numero,
    # altrimenti una media su due ticket su centosedici si legge come se li descrivesse tutti.
    it "dice su quante lavorazioni chiuse è calcolato" do
      first = create(:agent_workflow, organization:, triage_requested_at: 10.hours.ago, completed_at: 8.hours.ago)
      second = create(:agent_workflow, organization:, triage_requested_at: 6.hours.ago, completed_at: 5.hours.ago)
      concluded(workflow: first)
      concluded(workflow: second)
      concluded(workflow: create(:agent_workflow, organization:, completed_at: nil))

      report = described_class.call(host:)

      expect(report.workflow_tickets_count).to eq(2)
      expect(report.workflow_time?).to be(true)
    end

    # CYRA-499 — nessuna lavorazione chiusa = misura non calcolabile: la pagina non deve mostrarla
    # affatto, e il predicato è ciò che glielo dice.
    it "senza lavorazioni chiuse non è una misura da mostrare" do
      concluded

      report = described_class.call(host:)

      expect(report.workflow_tickets_count).to eq(0)
      expect(report.workflow_time?).to be(false)
      expect(report.host_time?).to be(true)
    end

    it "nemmeno il tempo dell'agente si mostra quando nessun tentativo ha un istante di fine" do
      create(:agent_attempt, organization:, host:, status: :cancelled,
                             workflow: create(:agent_workflow, organization:),
                             started_at: 2.hours.ago, finished_at: nil)

      report = described_class.call(host:)

      expect(report.any?).to be(true)
      expect(report.host_time?).to be(false)
    end
  end

  describe "piani rimandati indietro da una persona" do
    def plan_for(attempt, change_request: nil)
      Agents::Plan.create!(workflow: attempt.workflow, attempt:, version: 1, change_request:,
                           technical_analysis: "Analisi", scenarios: [], definition_of_done: [],
                           notes: [], ticket_snapshot_digest: "digest")
    end

    it "conta quelli con una richiesta di modifica sul totale dei piani prodotti" do
      plan_for(concluded(phase: "planner"), change_request: "Rifallo")
      plan_for(concluded(phase: "planner"))
      plan_for(concluded(phase: "planner"))
      plan_for(concluded(phase: "planner"))

      report = described_class.call(host:)

      expect(report.plans_total).to eq(4)
      expect(report.plans_sent_back).to eq(1)
      expect(report.plans_sent_back_pct).to eq(25.0)
    end

    it "senza piani la percentuale è nil, non zero" do
      expect(described_class.call(host:).plans_sent_back_pct).to be_nil
    end
  end

  describe "tempi per passaggio" do
    it "rende sempre tutte e cinque le fasi, anche quelle mai eseguite" do
      concluded(phase: "triage")

      rows = described_class.call(host:).by_phase

      expect(rows.map(&:phase)).to eq(Agents::PhaseProfile::PHASES)
      expect(rows.find { |row| row.phase == "closer_production" }.attempts).to eq(0)
    end

    it "per ogni fase dà conteggi ed esiti separati" do
      concluded(phase: "autopilot", status: :approved, seconds: 100)
      concluded(phase: "autopilot", status: :review_failed, seconds: 300)
      concluded(phase: "triage", status: :approved, seconds: 10)

      rows = described_class.call(host:).by_phase.index_by(&:phase)

      expect(rows["autopilot"].attempts).to eq(2)
      expect(rows["autopilot"].approved).to eq(1)
      expect(rows["autopilot"].rejected).to eq(1)
      expect(rows["autopilot"].avg_seconds).to eq(200)
      expect(rows["autopilot"].median_seconds).to eq(200)
      expect(rows["triage"].attempts).to eq(1)
    end

    it "ignora nella durata i tentativi senza istante di fine" do
      concluded(phase: "triage", seconds: 100)
      create(:agent_attempt, organization:, host:, phase: "triage", status: :stale,
                             workflow: create(:agent_workflow, organization:),
                             started_at: 1.hour.ago, finished_at: nil)

      row = described_class.call(host:).by_phase.find { |item| item.phase == "triage" }

      expect(row.attempts).to eq(2)
      expect(row.avg_seconds).to eq(100)
    end
  end

  describe "host senza storia" do
    it "risponde un report vuoto che sa di esserlo" do
      report = described_class.call(host:)

      expect(report).not_to be_any
      expect(report.attempts_count).to eq(0)
      expect(report.tickets_count).to eq(0)
      expect(report.by_phase.sum(&:attempts)).to eq(0)
    end
  end
  # CYRA-451 — il costo del periodo e la finestra precedente: senza, i numeri non dicono se l'host
  # stia migliorando né quanto sia costato il suo lavoro.
  describe "costo e periodo precedente" do
    it "somma le stime delle partenze concesse e conta quelle senza costo" do
      create(:agent_limit_reservation, organization:, host:, estimated_cost: "2.0000")
      create(:agent_limit_reservation, organization:, host:, estimated_cost: nil)
      create(:agent_limit_reservation, organization:, host:, estimated_cost: "3.0000", outcome: "denied",
                                       expires_at: nil, denial_reason: "max_daily_runs")

      cost = described_class.call(host:, range: "30d").cost

      expect(cost.total).to eq(BigDecimal("2"))
      expect(cost.tracked).to eq(1)
      expect(cost.untracked).to eq(1)
      expect(cost.partial?).to be(true)
    end

    it "senza nessuna partenza tracciata il costo non è disponibile, non è zero" do
      expect(described_class.call(host:, range: "30d").cost.any?).to be(false)
    end

    it "il periodo precedente guarda la finestra prima, non tutta la storia" do
      concluded(status: :approved, age: 2.days)
      concluded(status: :rejected, age: 40.days)

      current = described_class.call(host:, range: "30d")
      previous = described_class.call(host:, range: "30d", previous: true)

      expect(current.attempts_count).to eq(1)
      expect(previous.attempts_count).to eq(1)
      expect(previous.outcomes.rejected_pct).to eq(100.0)
    end

    it "su `all` il periodo precedente non esiste e non conta niente" do
      concluded(status: :approved, age: 400.days)

      previous = described_class.call(host:, range: "all", previous: true)

      expect(previous.any?).to be(false)
      expect(previous.cost.any?).to be(false)
    end
  end
end
