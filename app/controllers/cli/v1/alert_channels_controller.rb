# frozen_string_literal: true

module Cli
  module V1
    # Canali di consegna esterni degli alert (webhook firmato Slack/Discord/HTTP), org-level, gated da
    # alerts.manage. Stesso mapping di input del Member (flag del webhook → config jsonb); il
    # serializer NON espone mai il secret. destroy = eliminazione (le rule perdono il canale ma
    # continuano a consegnare in-app/email + Telegram personale dei destinatari).
    class AlertChannelsController < Cli::V1::BaseController
      before_action :require_alerts_management

      def index
        records, meta = paginate(Current.organization.alerting_channels.order(:name))
        render_ok(AlertChannelSerializer.new(records), meta: meta)
      end

      def create
        channel = Current.organization.alerting_channels.new(channel_attributes)
        channel.created_by = Current.account
        if channel.save
          render_created(AlertChannelSerializer.new(channel))
        else
          render_error("R422-ALERT-001", channel.errors.full_messages.to_sentence,
                       status: :unprocessable_content, details: channel.errors.to_hash)
        end
      end

      def destroy
        channel = Current.organization.alerting_channels.find(params[:id])
        channel.destroy
        render_no_content
      end

      private

      # Stesso mapping del Member: url → config jsonb, secret → colonna cifrata `webhook_secret`
      # (assegnata solo se fornita). Il serializer non espone mai il secret.
      def channel_attributes
        permitted = params.permit(:name, :kind, :enabled, :webhook_url, :webhook_secret)
        attrs = permitted.slice(:name, :kind, :enabled).to_h
        attrs[:config] = { "url" => permitted[:webhook_url].to_s }
        attrs[:webhook_secret] = permitted[:webhook_secret] if permitted[:webhook_secret].present?
        attrs[:enabled] = true unless params.key?(:enabled)
        attrs
      end

      def require_alerts_management
        require_permission!("alerts.manage")
      end
    end
  end
end
