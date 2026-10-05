# frozen_string_literal: true

module Ticketing
  module Notifications
    # Dato un Ticketing::Event notificabile, auto-iscrive l'interessato (reporter/assignee), calcola i
    # destinatari e consegna in-app + email rispettando le preferenze (tickets_enabled, canali, quiet
    # hours). Esclude SEMPRE l'attore dell'evento. Idempotente/difensivo: ticket o azione non
    # notificabile → no-op. Twin di Alerting::Evaluate, ma sui watcher invece che sulle regole.
    class DispatchEvent < ApplicationService
      def self.call(...) = new(...).call

      # Mappa azione → event_type della notifica (per tono/filtri). unassigned riusa ticket_assigned:
      # la categoria conta solo per le preferenze (tutti i ticket_* → tickets_enabled).
      ACTION_EVENT_TYPES = {
        "created" => :ticket_created,
        "assigned" => :ticket_assigned,
        "unassigned" => :ticket_assigned,
        "status_changed" => :ticket_status_changed,
        "milestone_changed" => :ticket_milestone_changed,
        "review_rejected" => :ticket_review_rejected,
        "review_approved" => :ticket_review_approved,
        # CYRA-782 — senza queste due righe una domanda non avvisa nessuno: la riga di cronologia
        # si scrive, il dispatcher non trova il tipo e la consegna esce zero, in silenzio.
        "question_asked" => :ticket_question_asked,
        "question_answered" => :ticket_question_answered
      }.freeze

      def initialize(event:, at: Time.current)
        @event = event
        @at = at
      end

      def call
        ticket = @event.ticket
        return Result.ok(0) if ticket.nil?

        event_type = ACTION_EVENT_TYPES[@event.action]
        return Result.ok(0) if event_type.nil?

        organization = ticket.project.organization
        auto_subscribe(ticket)
        # Contenuto snapshottato nella lingua del DESTINATARIO, memoizzato per locale (max |LOCALES|).
        content_for = Hash.new do |cache, locale|
          cache[locale] = I18n.with_locale(locale) { Content.for(event: @event) }
        end

        delivered = 0
        # Ping dedicati: al reviewer sull'ingresso in uno status review_gate (#review_recipient),
        # all'assignee sulla review respinta col motivo (#rejection_recipient). Chi riceve il ping
        # è escluso dal giro generico (niente doppione dello stesso evento).
        reviewer = review_recipient(ticket)
        delivered += deliver_review(reviewer, ticket, organization) if reviewer
        rejected_assignee = rejection_recipient(ticket)
        delivered += deliver_rejection(rejected_assignee, ticket, organization) if rejected_assignee

        recipients(ticket).each do |account|
          next if account.id == @event.actor_id
          next if reviewer && account.id == reviewer.id
          next if rejected_assignee && account.id == rejected_assignee.id

          delivered += deliver_to(account, ticket, organization, event_type, content_for[account.effective_locale])
        end
        Result.ok(delivered)
      end

      private

      # L'evento "porta dentro" il suo protagonista: chi crea diventa watcher (per gli eventi futuri),
      # chi viene assegnato diventa watcher (e riceve la notifica di assegnazione). Idempotente.
      # Alla creazione iscriviamo ANCHE l'assegnatario impostato in fase di create (CreateTicket non
      # emette un evento "assigned" separato) così resta nel loop sugli eventi futuri.
      def auto_subscribe(ticket)
        case @event.action
        when "created"
          # simplecov:disable reporter_id è null:false → un ticket persistito ha sempre un reporter; il ramo
          # `if ticket.reporter` falso è irraggiungibile (il ticket sparito esce prima al guard ticket.nil?).
          Subscription.ensure_for(ticket: ticket, account: ticket.reporter, source: :reporter) if ticket.reporter
          # simplecov:enable
          Subscription.ensure_for(ticket: ticket, account: ticket.assignee, source: :assignee) if ticket.assignee
        when "assigned"
          Subscription.ensure_for(ticket: ticket, account: ticket.assignee, source: :assignee) if ticket.assignee
        end
      end

      # created → SOLO l'assegnatario, e solo se diverso dal reporter (niente blast al team → spam).
      # Altri eventi → i watcher del ticket (auto-subscribe garantisce reporter/assignee nel set).
      def recipients(ticket)
        if @event.action == "created"
          created_recipients(ticket)
        else
          ticket.subscribers.to_a
        end
      end

      def created_recipients(ticket)
        assignee = ticket.assignee
        return [] if assignee.nil? || assignee.id == ticket.reporter_id

        [ assignee ]
      end

      def deliver_to(account, ticket, organization, event_type, content)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(event_type, connected_telegram: account.connected_telegram?)

        count = 0
        count += deliver_in_app(account, ticket, organization, event_type, content) # in-app SEMPRE
        telegram = deliver_telegram(account, ticket, organization, event_type, content, channels[:telegram])
        unless ::Notifications::Deliver.reached_by_telegram?(telegram)
          count += deliver_email(account, ticket, organization, event_type, content, pref, channels[:email])
        end
        count + (telegram&.ok? ? 1 : 0)
      end

      def deliver_in_app(account, ticket, organization, event_type, content)
        result = Deliver.in_app(
          account: account, ticket: ticket, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, ticket, organization, event_type, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, ticket: ticket, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, ticket, organization, event_type, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, ticket: ticket, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      # Una notifica per (evento, account, canale). L'evento è già univoco per mutazione → niente
      # finestra/throttle come negli alert: un solo invio per cambiamento.
      def dedup_key(account, via)
        "ticket:#{@event.id}:#{account.id}:#{via}"
      end

      # Reviewer da avvisare: non-nil SOLO se questo evento è l'ingresso in uno status review_gate,
      # c'è un revisore, e il revisore non è l'attore del cambio (niente auto-notifica). ticket.status
      # è lo status appena impostato (letto post-commit dal NotifyJob).
      def review_recipient(ticket)
        return nil unless @event.action == "status_changed"

        # simplecov:disable ticket.status è null:false → su un ticket persistito lo status è sempre presente;
        # l'arm `&.` nil è difesa irraggiungibile (i rami review_gate? true/false restano esercitati
        # dagli spec del review_gate ping).
        return nil unless ticket.status&.review_gate?
        # simplecov:enable

        reviewer = ticket.reviewer
        return nil if reviewer.nil? || reviewer.id == @event.actor_id

        reviewer
      end

      # Assignee da avvisare col motivo: non-nil SOLO se questo evento è una review respinta,
      # c'è un assegnatario, e non è l'attore del rifiuto (niente auto-notifica).
      def rejection_recipient(ticket)
        return nil unless @event.action == "review_rejected"

        assignee = ticket.assignee
        return nil if assignee.nil? || assignee.id == @event.actor_id

        assignee
      end

      # Ping "pronto per la revisione" al reviewer (event_type ticket_review_requested). Content nella
      # lingua del reviewer (destinatario unico e noto del ping).
      def deliver_review(reviewer, ticket, organization)
        content = I18n.with_locale(reviewer.effective_locale) { Content.review(event: @event) }
        deliver_ping(reviewer, ticket, organization,
                     event_type: :ticket_review_requested, content: content, segment: "review")
      end

      # Ping "review respinta" all'assignee: il body del content è il motivo del rifiuto. Content nella
      # lingua dell'assignee (destinatario unico e noto del ping).
      def deliver_rejection(assignee, ticket, organization)
        content = I18n.with_locale(assignee.effective_locale) { Content.review_rejected(event: @event) }
        deliver_ping(assignee, ticket, organization,
                     event_type: :ticket_review_rejected, content: content, segment: "review_rejected")
      end

      # Ping dedicato: stesse guardie di deliver_to (cadenza per-notifica per canale), ma event_type
      # e content propri e dedup key distinta per segmento → coesiste con l'eventuale notifica
      # generica dello stesso evento/account/canale senza collidere sull'unique [rule_id, dedup_key].
      def deliver_ping(account, ticket, organization, event_type:, content:, segment:)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(event_type, connected_telegram: account.connected_telegram?)

        count = 0
        # In-app SEMPRE.
        in_app = Deliver.in_app(
          account: account, ticket: ticket, organization: organization,
          event_type: event_type, content: content, dedup_key: ping_dedup_key(account, segment, "in_app")
        )
        count += 1 if in_app.ok?

        if channels[:telegram][:deliver]
          telegram = Deliver.telegram(
            account: account, ticket: ticket, organization: organization,
            event_type: event_type, content: content,
            dedup_key: ping_dedup_key(account, segment, "telegram"), bucket: channels[:telegram][:bucket]
          )
          count += 1 if telegram.ok?
        end
        # La mail resta la riserva di Telegram (CYRA-853).
        if channels[:email][:deliver] && !::Notifications::Deliver.reached_by_telegram?(telegram)
          email = Deliver.email(
            account: account, ticket: ticket, organization: organization,
            event_type: event_type, content: content,
            dedup_key: ping_dedup_key(account, segment, "email"),
            quiet: pref.quiet_now?(at: @at), bucket: channels[:email][:bucket]
          )
          count += 1 if email.ok?
        end
        count
      end

      def ping_dedup_key(account, segment, via)
        "ticket:#{@event.id}:#{account.id}:#{segment}:#{via}"
      end
    end
  end
end
