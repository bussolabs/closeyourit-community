# frozen_string_literal: true

module Cli
  module V1
    # Notification center personale via CLI: l'utente vede/gestisce SOLO le proprie notifiche in-app.
    # Ownership (own_notifications), nessuna permission key (è la propria casella) — specchio di
    # Member::AlertingNotificationsController. Anti-BOLA: un id altrui → RecordNotFound → R404.
    class AlertNotificationsController < Cli::V1::BaseController
      before_action :set_notification, only: %i[read destroy]

      def index
        records, meta = paginate(own_notifications.includes(:subject).recent)
        render_ok(AlertNotificationSerializer.new(records),
                  meta: meta.merge(unread: own_notifications.unread.count))
      end

      # PUT: marca letta la singola notifica (idempotente: già letta = no-op).
      def read
        @notification.mark_read!
        render_ok(AlertNotificationSerializer.new(@notification))
      end

      # PUT collection: marca lette TUTTE le non lette dell'utente. Ritorna quante ne ha segnate.
      def read_all
        count = own_notifications.unread.update_all(read_at: Time.current)
        render_ok({ marked_read: count })
      end

      def destroy
        @notification.destroy
        render_no_content
      end

      private

      def own_notifications
        Alerting::Notification.where(account_id: Current.account.id,
                                     organization_id: Current.organization.id, via: :in_app)
      end

      def set_notification
        @notification = own_notifications.find(params[:id])
      end
    end
  end
end
