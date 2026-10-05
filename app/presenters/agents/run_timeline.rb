# frozen_string_literal: true

module Agents
  # Percorso di UNA lavorazione attiva nella pagina host (CYRA-183): i cinque passaggi in ordine con lo
  # stato di ciascuno, più ciò che la lavorazione ha prodotto finora. Risponde a «a che punto è» senza
  # aprire il ticket e ricomporre i pezzi a mano.
  #
  # La sequenza è `PhaseProfile::PHASES` — la stessa che decide runtime/skill/TTL — non un elenco
  # riscritto nella vista: se domani nasce una fase, compare qui senza toccare la UI.
  #
  # Lo stato di ogni passaggio è DERIVATO dai timestamp del workflow (nessuna colonna nuova, nessuno
  # stato duplicato che possa divergere). La fase **in corso** arriva dal LEASE, non dai timestamp:
  # il lease è ciò che l'host detiene davvero in questo istante, quindi la pagina non può raccontare
  # una fase diversa da quella che l'host sta eseguendo.
  class RunTimeline
    # done    = concluso (ha il suo timestamp di completamento)
    # current = in corso ORA (fase del lease attivo)
    # pending = non ancora iniziato
    Step = Data.define(:phase, :status, :completed_at) do
      def done? = status == :done
      def current? = status == :current
    end

    # Cosa la lavorazione ha prodotto finora. Tutti opzionali: una lavorazione appena reclamata non ha
    # ancora nulla, e la vista deve poterlo dire senza inventare zeri.
    Products = Data.define(:plan_version, :attempts_count, :branch_name, :pull_request_number)

    # Completamento per fase: la chiave è la fase, il valore la colonna che ne attesta la fine.
    # `closer_production` chiude col `completed_at` del workflow (non esiste una colonna dedicata).
    COMPLETED_AT = {
      "triage" => :triaged_at,
      "planner" => :planned_at,
      "autopilot" => :autopilot_completed_at,
      "closer_staging" => :closer_staging_completed_at,
      "closer_production" => :completed_at
    }.freeze

    # Inizio per fase, per riconoscere una lavorazione GIÀ AVVIATA. `planner` non ha una colonna di
    # inizio propria: comincia quando il triage chiude.
    STARTED_AT = {
      "triage" => :triage_started_at,
      "planner" => :triaged_at,
      "autopilot" => :autopilot_started_at,
      "closer_staging" => :closer_staging_started_at,
      "closer_production" => :closer_production_started_at
    }.freeze

    def initialize(workflow:, current_phase: nil)
      @workflow = workflow
      @current_phase = current_phase.presence || in_flight_phase
    end

    def steps
      PhaseProfile.phases.map do |phase|
        completed_at = @workflow && COMPLETED_AT[phase] ? @workflow.public_send(COMPLETED_AT[phase]) : nil
        Step.new(phase:, status: status_for(phase, completed_at), completed_at:)
      end
    end

    # Ciò che è stato prodotto. Legge dalle associazioni già precaricate dal controller: nessuna query
    # per riga (la sezione può elencare più lavorazioni).
    def products
      return Products.new(plan_version: nil, attempts_count: 0, branch_name: nil, pull_request_number: nil) unless @workflow

      Products.new(
        plan_version: @workflow.plans.map(&:version).max,
        attempts_count: @workflow.attempts.size,
        branch_name: ticket_branch&.name,
        pull_request_number: ticket_pull_request&.number
      )
    end

    private

    # Fase avviata e non ancora conclusa, dedotta dai timestamp. Serve ai lease legacy (pre host-first)
    # che non portano `execution_phase`: `ready_execution_phase` non copre questo caso — dice quale fase è
    # RECLAMABILE, e una fase già avviata non lo è più, quindi lì restituisce nil e nessun passaggio
    # risulterebbe in corso. Si prende l'ultima avviata: un workflow avanzato non torna indietro.
    def in_flight_phase
      return nil unless @workflow

      PhaseProfile.phases.reverse.find do |phase|
        started = STARTED_AT[phase] && @workflow.public_send(STARTED_AT[phase])
        completed = COMPLETED_AT[phase] && @workflow.public_send(COMPLETED_AT[phase])
        started.present? && completed.blank?
      end
    end

    # Precedenza: la fase del lease vince sempre. Un passaggio con timestamp di completamento è concluso;
    # gli altri restano da fare. Una fase può risultare `current` anche se già conclusa in un giro
    # precedente (retry): è corretto, l'host la sta rieseguendo adesso.
    def status_for(phase, completed_at)
      return :current if phase == @current_phase
      return :done if completed_at.present?

      :pending
    end

    def ticket_branch
      @workflow.ticket.github_branches.max_by(&:created_at)
    end

    def ticket_pull_request
      @workflow.ticket.github_pull_requests.max_by(&:created_at)
    end
  end
end
