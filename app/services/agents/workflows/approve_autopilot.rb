# frozen_string_literal: true

module Agents
  module Workflows
    # B.4 — Gate umano DOPO l'autopilot. Il reviewer approva la consegna dell'autopilot e il workflow
    # avanza ai closer. A differenza di Ticketing::ApproveReview "normale" (che porta il ticket a done),
    # qui il ticket resta in un in_progress NON review-gate: la coda closer_staging esclude i ticket in
    # categoria done (vedi TicketQueues::Next), quindi mandarlo a done bloccherebbe la pipeline.
    # Timbra autopilot_approved_at + autopilot_approved_by (phase → closer_staging_queued).
    # Invocato in delega da Ticketing::ApproveReview, che ne fa il gate di permesso/autorizzazione.
    class ApproveAutopilot < ApplicationService
      def initialize(workflow:, actor:, client: nil)
        @workflow = workflow
        @actor = actor
        @client = client
      end

      # La fase in cui la lavorazione si trova SUBITO DOPO il sì (workflow.rb: `autopilot_approved_at`
      # → `closer_staging_queued`). Serve prima di scrivere, per chiedere al cancello la categoria
      # giusta senza dipendere da come l'organizzazione ha configurato i suoi stati.
      PHASE_AFTER_APPROVAL = "closer_staging_queued"

      def call
        outcome = nil
        # CYRA-617 — nell'istante del tuo sì si va a chiedere al servizio COSA C'È DENTRO ADESSO, e lo
        # si confronta con quello che era stato controllato e mostrato. Prima, fra il controllo e il
        # clic, chiunque poteva metterci dentro altro codice — una persona o una sessione ripresa — e
        # nessuno ricontrollava niente: andava avanti codice che nessuno aveva mai guardato, con tutte
        # le spie verdi.
        #
        # FUORI dalla transazione, e non è un dettaglio: `BulkApprove` accetta fino a cento schede in
        # una volta, e il client ha 5 s di apertura più 15 di lettura. Un HTTP dentro la transazione
        # terrebbe righe bloccate per minuti su una rete lenta.
        observed = observe_delivered_code
        return observed if observed.is_a?(Result)

        ApplicationRecord.transaction do
          @workflow.lock!
          @workflow.ticket.lock!
          return stale unless @workflow.phase == "awaiting_autopilot_approval"
          # Sotto lock si ricontrolla che il verbale sia ancora QUELLO: fra la lettura di sopra e qui
          # un altro giro di verifica può averlo sostituito, e allora il confronto appena fatto
          # riguarda una cosa che non è più quella su cui si sta decidendo.
          return stale if observed && @workflow.review_candidate_id != observed[:candidate_id]
          return code_changed!(observed) if observed && observed[:head_sha] != observed[:approved_sha]

          # Gate dipendenze (CYRA-81) PRIMA di ogni scrittura e PRIMA di risolvere la destinazione
          # (CYRA-622): la categoria da proteggere si legge dalla FASE a cui l'approvazione porta, non
          # da una riga di stato. Prima si risolveva la riga per prima, e in un'organizzazione senza
          # destinazione configurata il cancello non girava affatto: una configurazione mancante
          # spegneva un controllo che non c'entra niente con la configurazione.
          #
          # `:merged` e non `:released`: «va dopo» vuol dire «aspetta che il codice dell'altro sia
          # unito e provato», non «aspetta che l'altro sia vivo in produzione». Con la domanda severa
          # due ticket messi in fila si bloccavano a vicenda e il secondo pagava un giro di rilascio
          # intero di attesa. Ricontrollo sotto lock nella stessa transazione (workflow + ticket sono
          # già lockati sopra): su blocco nessuna mutazione e ApproveReview propaga l'errore senza
          # broadcastare.
          guard = Ticketing::DependencyGuard.call(
            ticket: @workflow.ticket,
            target_category: StatusProjection.category(PHASE_AFTER_APPROVAL),
            mode: StatusProjection.prerequisites(PHASE_AFTER_APPROVAL)
          )
          return guard if guard.err?

          # Approvare torna a essere SOLO la decisione di una persona: qui si registra chi e quando.
          # La parola sul ticket la scrive la proiezione fase→stato, unico posto che conosce la
          # corrispondenza — qui la si consuma soltanto. Con la data appena scritta la fase è già
          # `closer_staging_queued`, quindi la proiezione trova da sé la destinazione giusta.
          @workflow.update!(autopilot_approved_by: @actor, autopilot_approved_at: Time.current)
          # L'annuncio lo fa `ApproveReview`, che sa se questa è una di cento approvazioni in una sola
          # richiesta: da qui partirebbe comunque, ma una card per volta.
          projection = StatusProjection.call(workflow: @workflow, actor: @actor, broadcast: false)
          if projection.err?
            outcome = projection
            raise ActiveRecord::Rollback
          end
        end
        outcome || Result.ok(@workflow)
      rescue ActiveRecord::RecordNotFound
        stale
      end

      private

      def stale
        Result.err(AppError.new("Il workflow non è più approvabile dopo l'autopilot",
                                code: "R409-WORKFLOW-003", status: :conflict))
      end

      def client = @client ||= Github::Client.new

      # Legge lo stato vivo della proposta e restituisce cosa serve al confronto, oppure un Result di
      # errore. Nil quando non c'è niente da confrontare: una lavorazione senza verbale congelato non
      # è passata da questa strada, e pretendere un confronto che non si può fare fermerebbe lavoro
      # sano — il verbale lo pretende chi mette la scheda davanti a una persona, non questo passo.
      def observe_delivered_code
        candidate = @workflow.review_candidate
        return nil if candidate.nil? || candidate.head_sha.blank?

        repository = candidate.repository
        return nil if repository.nil?

        state = client.pull_request_state(repository.github_installation_id, candidate.repository_full_name,
                                          candidate.number)
        { candidate_id: candidate.id, approved_sha: candidate.head_sha, head_sha: state[:head_sha] }
      rescue Github::Client::Error => e
        e.status == :not_found ? pull_request_gone : unreachable(e)
      end

      # Il codice è cambiato dopo il controllo. La lavorazione esce dalla pila delle decisioni e torna
      # fra i lavori in corso: si azzera la firma della verifica e si rimette una riga da controllare,
      # così il sistema riguarda il codice nuovo e poi torna da chi deve approvare. In produzione non
      # è andato niente.
      #
      # `head_sha: nil` sulla riga nuova: la sigla la congela chi va a guardare, che è l'unico che l'ha
      # letta dal servizio. Scriverla qui vorrebbe dire fidarsi di una lettura fatta per un altro scopo.
      def code_changed!(observed)
        candidate = @workflow.review_candidate
        ApplicationRecord.transaction do
          @workflow.update!(candidate_verified_at: nil, review_candidate_id: nil)
          Agents::DeliveryCandidate.find_or_create_by!(
            workflow: @workflow, repository_full_name: candidate.repository_full_name,
            number: candidate.number, head_sha: nil
          ) do |row|
            row.attempt = candidate.attempt
            row.repository = candidate.repository
            row.state = :pending
            row.next_check_at = Time.current
          end
        end
        Result.err(AppError.new(I18n.t("member.tickets.errors.code_changed_after_check",
                                       approved: observed[:approved_sha].first(12),
                                       current: observed[:head_sha].to_s.first(12)),
                                code: "R409-WORKFLOW-005", status: :conflict))
      end

      # «Non ho potuto guardare» e «il codice è cambiato» sono due cose diverse e restano due messaggi
      # diversi: qui non si azzera niente e la lavorazione non risulta ferma. Il controllo già fatto
      # resta buono, e si può riprovare fra poco.
      def unreachable(error)
        Result.err(AppError.new(I18n.t("member.tickets.errors.check_unreachable"),
                                code: "R409-WORKFLOW-006", status: :conflict, details: { github: error.code }))
      end

      # La proposta non esiste più: qui non c'è niente da ricontrollare, e infatti non si rimette
      # nessuna riga da guardare.
      def pull_request_gone
        Result.err(AppError.new(I18n.t("member.tickets.errors.pull_request_gone"),
                                code: "R409-WORKFLOW-007", status: :conflict))
      end
    end
  end
end
