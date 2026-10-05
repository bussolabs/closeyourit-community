# frozen_string_literal: true

module Notifications
  # La consegna di UNA notifica personale, per tutti i domini. È il punto solo: avvisi, chat, vault,
  # ticket e credenziali di ingest arrivano qui e si distinguono soltanto per il payload che
  # preparano (Notifications::Payload). Prima erano tredici file della stessa forma e una correzione
  # — quella di CYRA-672 sullo stato «inviata» — andava scritta cinque volte (CYRA-744).
  #
  # I tre canali personali scrivono la riga in Alerting::Notification e la deduplicano sulla
  # dedup_key: unique [rule_id, dedup_key] per le notifiche di una regola, indice parziale
  # (account_id, dedup_key) WHERE rule_id IS NULL per i dispatch diretti. Una seconda consegna nella
  # stessa finestra torna Result.err e non manda niente — è così che è fatto il throttle.
  class Deliver < ApplicationService
    # In-app non si disattiva e non si differisce: la riga È la consegna.
    def self.in_app(payload:) = new(payload: payload, via: :in_app).call

    # quiet: le ore silenziose del destinatario. bucket: :daily/:weekly quando ha scelto il riassunto.
    def self.email(payload:, quiet: false, bucket: nil)
      new(payload: payload, via: :email, quiet: quiet, bucket: bucket).call
    end

    # Nessuna ora silenziosa qui: chi vuole il differimento sceglie una cadenza (bucket). Il
    # chiamante garantisce già canale acceso e account collegato (Preference#channels_for).
    def self.telegram(payload:, bucket: nil) = new(payload: payload, via: :telegram, bucket: bucket).call

    # La mail di un avviso che Telegram ha già portato non parte: resta la riserva quando Telegram
    # fallisce o non è stato tentato. Il doppione conta come portato: la finestra l'ha già deciso (CYRA-853).
    def self.reached_by_telegram?(result) = result.present? && (result.err? || result.value.status_sent?)

    # Canale ESTERNO della regola (Slack/Discord/HTTP): va per canale e non per destinatario, non ha
    # una riga da scrivere né uno stato da segnare. Stesso punto d'ingresso, motore suo.
    def self.webhook(channel:, event_type:, subject:, content:)
      Webhook.call(channel: channel, event_type: event_type, subject: subject, content: content)
    end

    def initialize(payload:, via:, quiet: false, bucket: nil)
      @payload = payload
      @via = via
      @quiet = quiet
      @bucket = bucket
    end

    def call
      notification = build_notification
      return Result.err(@payload.duplicate_error) unless save_unique(notification)

      deliver(notification)
      Result.ok(notification)
    end

    private

    def build_notification
      Alerting::Notification.new(
        organization: @payload.organization, project: @payload.project, account: @payload.account,
        rule: @payload.rule, subject: @payload.subject, via: @via, event_type: @payload.event_type,
        title: @payload.title, body: @payload.body, url: @payload.url, details: @payload.details,
        dedup_key: @payload.dedup_key, status: status_for, digest_bucket: @bucket,
        delivered_at: @via == :in_app ? Time.current : nil
      )
    end

    # In-app è consegnata nell'istante in cui la riga esiste (è la riga stessa). Email e Telegram
    # restano :queued col bucket del digest, :held nelle ore silenziose e altrimenti :pending — MAI
    # :sent qui: `deliver_later` ACCODA soltanto, ed è Notifications::DeliveryObserver a vedere il
    # messaggio uscire davvero; Telegram si segna da sé sull'esito della chiamata (CYRA-672).
    def status_for
      return :sent if @via == :in_app
      return :queued if @bucket

      held? ? :held : :pending
    end

    # ECCEZIONE (CYRA-479): un evento CRITICO — guasto grave di infrastruttura — scavalca le ore
    # silenziose, perché di notte l'email è l'unico canale che sveglia. Il bypass vale SOLO per il
    # silenzio, non per il digest: chi ha scelto una cadenza per quell'evento resta in coda (il
    # bucket ha la precedenza). La classificazione è di Notifications::Catalog: niente lista qui.
    def held? = @quiet && !Notifications::Catalog.critical?(@payload.event_type)

    # Parte adesso solo se non c'è una cadenza scelta e il silenzio non la trattiene.
    def immediate? = @bucket.nil? && !held?

    def deliver(notification)
      if @via != :in_app && DevelopmentLab.organization?(@payload.organization)
        notification.update!(status: :skipped)
        Rails.logger.info("[notifications] lab_intercepted notification_id=#{notification.id} via=#{@via}")
        return
      end

      case @via
      when :in_app then broadcast(notification)
      when :email then deliver_email(notification) if immediate?
      when :telegram then deliver_telegram(notification) if @bucket.nil?
      end
    end

    def deliver_email(notification)
      raise ArgumentError, "payload senza mailer: il canale email non sa quale pagina spedire" if @payload.mailer.nil?

      @payload.mailer.call(notification).deliver_later
    end

    # Telegram::Send ha un rescue interno e RESTITUISCE un Result: non solleva mai. Buttare quel
    # valore vuol dire scrivere «inviata» anche quando il bot non è configurato, la chat manca o
    # Telegram risponde con un errore.
    def deliver_telegram(notification)
      text = ::Notifications::TelegramText.for(notification)
      group = Alerting::TelegramGroup.for_recipient(account: @payload.account, organization: @payload.organization)
      outcome = if group # l'owner col gruppo con argomenti lo riceve lì, non in privato (CYRA-852)
        ::Telegram::SendToGroup.call(group: group, event_type: @payload.event_type, text: text)
      else
        ::Telegram::Send.call(chat_id: @payload.account.telegram_chat_id, text: text, parse_mode: "HTML")
      end

      notification.update!(outcome.ok? ? { status: :sent, delivered_at: Time.current } : { status: :failed })
    end

    # La validation uniqueness rende save=false sui doppioni; il rescue copre la race concorrente
    # (ApplicationJob ritenta 3×), dove due processi passano insieme la validation e l'indice decide.
    def save_unique(notification)
      notification.save
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def broadcast(notification)
      stream = "alerting:notifications:#{@payload.account.id}"
      Turbo::StreamsChannel.broadcast_prepend_to(
        stream, target: "notifications",
        partial: "member/alerting_notifications/notification",
        locals: { group: Alerting::NotificationGroup.new(notification) }
      )
      Turbo::StreamsChannel.broadcast_replace_to(
        stream, target: "alerting_notification_badge",
        partial: "member/alerting_notifications/badge", locals: { count: unread_count }
      )
    end

    def unread_count
      Alerting::Notification.where(account_id: @payload.account.id, via: :in_app).unread.count
    end
  end
end
