# frozen_string_literal: true

module Home
  module Approvals
    # Accetta in un colpo le card selezionate nella pila (CYRA-284). Non contiene logica di dominio e
    # nemmeno di permessi: risolve ogni chiave con Home::Approvals::Detail — che è il gate — e passa
    # la parola a Home::Approvals::Decide, la stessa strada della decisione singola.
    #
    # NIENTE transazione unica, deliberatamente. I service di dominio notificano e broadcastano
    # assumendo di aver già committato (è il motivo per cui Decide non avvolge Ticketing::AddComment),
    # e una card andata male non deve annullare quelle riuscite: chi ha smaltito venti approvazioni
    # non può ritrovarsele tutte indietro perché la ventunesima era stale. Best-effort, esito contato.
    #
    # In blocco non si scrive nessuna nota: la nota è il testo che accompagna UNA decisione, e su una
    # selezione diventerebbe lo stesso commento copiato su N ticket diversi.
    #
    #   Home::Approvals::BulkApprove.call(account:, organization:, visible_projects:,
    #     visible_tickets:, keys: ["review:…", "agent_plan:…"]) → Result<Outcome>
    class BulkApprove < ApplicationService
      # Tetto alle chiavi accettate in una volta: la pila non ne mostra più di così (Queue::PAGE_LIMIT),
      # quindi oltre non c'è una selezione ma un payload costruito a mano. Si rifiuta invece di tagliare:
      # una selezione troncata in silenzio direbbe "fatto" su un lavoro fatto a metà.
      MAX_KEYS = Queue::PAGE_LIMIT

      Failure = Data.define(:key, :message)

      # `approved`/`skipped` = quante ne sono andate e quante sono state scartate perché non idonee o
      # non mie; `failures` = quelle tentate e fallite, con il motivo.
      Outcome = Data.define(:approved, :skipped, :failures) do
        def failed = failures.size
        def any? = approved.positive?
      end

      def initialize(account:, organization:, visible_projects:, visible_tickets:, keys:, true_actor: nil)
        @account = account
        @organization = organization
        @visible_projects = visible_projects
        @visible_tickets = visible_tickets
        @keys = Array(keys).map { |key| key.to_s.strip }.reject(&:blank?).uniq
        @true_actor = true_actor
      end

      def call
        return no_keys if @keys.empty?
        return too_many if @keys.size > MAX_KEYS

        approved = 0
        skipped = 0
        failures = []
        approved_tickets = []
        @keys.each do |key|
          card = resolve(key)
          next skipped += 1 unless card&.bulk_approvable?

          result = safe_approve(card, key)
          if result.ok?
            approved += 1
            approved_tickets << result.value if result.value.is_a?(Ticketing::Ticket)
          else
            failures << Failure.new(key: key, message: result.error.message)
          end
        end
        refresh_dependents_boards(approved_tickets)
        Result.ok(Outcome.new(approved: approved, skipped: skipped, failures: failures))
      end

      private

      # Chiave illeggibile, card che non mi compete, card non idonea al blocco: tutte SALTATE, mai un
      # errore. Detail risolve dagli scope visibili, quindi qui non si distingue "non esiste" da "non
      # è mia" — ed è esattamente ciò che si vuole (anti-BOLA).
      def resolve(key)
        Detail.call(account: @account, organization: @organization, visible_projects: @visible_projects,
                    visible_tickets: @visible_tickets, key: key)
      end

      # Best-effort vuol dire anche questo: un service di dominio che SOLLEVA conta come una card
      # andata male, non come la fine della richiesta (CYRA-289). Prima l'eccezione propagava fino al
      # controller — 500 — mentre le card già accettate erano passate davvero e nessuna transazione le
      # riportava indietro: chi guardava la pagina d'errore non aveva modo di sapere quali. È successo
      # in produzione con il lock del database dei broadcast, ma la forma del guasto non dipende dalla
      # causa: venti approvazioni non si perdono per la ventunesima.
      #
      # Il rescue è largo apposta (StandardError), e per questo lascia traccia nel log: il resoconto
      # dice all'utente che una non è passata, il log dice a noi perché. Il messaggio dell'eccezione
      # resta NEL LOG e non entra nel messaggio a schermo: un guasto interno può portarsi dietro SQL,
      # nomi di colonna o frammenti di dati, e quel testo finisce dritto in un flash che l'utente legge.
      # Verso l'interfaccia va una frase generica, come per ogni altro errore di questa pagina.
      def safe_approve(card, key)
        approve(card)
      rescue StandardError => e
        Rails.logger.warn("BulkApprove: #{key} non accettata — #{e.class}: #{e.message}")
        Result.err(AppError.new(I18n.t("member.approvals.errors.card_failed"), code: "R500-APPROVAL-006"))
      end

      # La card è già risolta: la si passa a Decide perché non la risolva una seconda volta. Il gate
      # non si sposta — è la stessa card che lo ha superato un attimo fa.
      #
      # `broadcast_dependents: false`: il refresh delle board dei dependents NON si fa per card. Una
      # query per card dentro questo loop è un N+1 vero (il guard Prosopite fa fallire la richiesta già
      # alla seconda card accettata, CYRA-82) e il lavoro è lo stesso: lo fa una volta sola
      # refresh_dependents_boards, sul lotto intero.
      def approve(card)
        Decide.call(account: @account, organization: @organization, visible_projects: @visible_projects,
                    visible_tickets: @visible_tickets, key: card.key, decision: :approve,
                    true_actor: @true_actor, card: card, broadcast_dependents: false)
      end

      # Un refresh solo per tutte le board che ospitano dependents delle card accettate: UNA query,
      # qualunque sia il numero di card. Best-effort come il resto del blocco — le approvazioni sono già
      # committate, e un broadcast che fallisce non deve trasformarle in un errore: il peggio che può
      # succedere è una board che si aggiorna al prossimo caricamento.
      #
      # Riceve SOLO i ticket che hanno davvero cambiato stato (il Result di Ticketing::ApproveReview,
      # l'unico che ritorna un ticket), non tutte le card che ne portano uno. La differenza non è
      # cosmetica: DependentsBoardRefresh esclude i progetti dei ticket passati perché dà per scontato
      # che quelle board le abbia già rinfrescate broadcast_status_change. Un piano approvato
      # (Agents::Workflows::ApprovePlan) non cambia stato al ticket e non rinfresca niente: infilarlo qui
      # farebbe escludere il suo progetto da un refresh che nessuno ha fatto, e un dependent che vive lì
      # resterebbe col badge "bloccato" vecchio fino al prossimo caricamento.
      def refresh_dependents_boards(tickets)
        return if tickets.empty?

        Ticketing::DependentsBoardRefresh.call(tickets: tickets)
      rescue StandardError => e
        Rails.logger.warn("BulkApprove: refresh board dependents fallito — #{e.class}: #{e.message}")
      end

      def no_keys
        Result.err(AppError.new(I18n.t("member.approvals.errors.no_selection"), code: "R422-APPROVAL-004"))
      end

      def too_many
        Result.err(AppError.new(I18n.t("member.approvals.errors.too_many", max: MAX_KEYS),
                                code: "R422-APPROVAL-005"))
      end
    end
  end
end
