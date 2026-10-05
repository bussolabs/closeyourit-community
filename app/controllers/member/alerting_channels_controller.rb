# frozen_string_literal: true

module Member
  # Canali di consegna esterni (webhook Slack/Discord/HTTP) per gli alert. CRUD org-level gated da
  # alerts.manage. Controller flat per non ombreggiare il namespace di dominio ::Alerting.
  class AlertingChannelsController < Member::BaseController
    # Whitelist ordinamento (contratto Sortable#sorted). Target (config jsonb) resta statico.
    SORT_COLUMNS = {
      "name" => "LOWER(alerting_channels.name)",
      "kind" => :kind,
      "rules" => "(SELECT COUNT(*) FROM alerting_rule_channels rc WHERE rc.channel_id = alerting_channels.id)",
      "status" => :enabled
    }.freeze

    before_action :require_manage
    before_action :set_channel, only: %i[edit update destroy]

    def index
      @channels = sorted(Current.organization.alerting_channels.order(:name), columns: SORT_COLUMNS).to_a
      # Conteggio regole per canale in batch (la riga mostra channel.rules.count → N+1 senza questo).
      @rule_counts = Alerting::RuleChannel.where(channel_id: @channels.map(&:id)).group(:channel_id).count
    end

    def new
      @channel = Current.organization.alerting_channels.new(kind: :webhook, enabled: true)
    end

    def create
      @channel = Current.organization.alerting_channels.new(created_by: Current.account)
      if @channel.update(channel_attributes)
        redirect_to member_alerting_channels_path, notice: t("member.alerting.channels.created")
      else
        @errors = @channel.errors.to_hash
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @channel.update(channel_attributes)
        redirect_to member_alerting_channels_path, notice: t("member.alerting.channels.updated")
      else
        @errors = @channel.errors.to_hash
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @channel.destroy
      redirect_to member_alerting_channels_path, notice: t("member.alerting.channels.deleted")
    end

    private

    def require_manage
      require_permission!("alerts.manage")
    end

    def set_channel
      @channel = Current.organization.alerting_channels.find(params[:id])
    end

    # La config del webhook si assembla dai campi piatti del form (mai jsonb crudo dal client).
    # url → config JSONB (non segreto); secret → colonna cifrata `webhook_secret`, assegnata solo se
    # fornita così l'update NON azzera il secret esistente (il form non lo ripopola: blank = invariato).
    def channel_attributes
      permitted = params.permit(:name, :kind, :enabled, :webhook_url, :webhook_secret)
      attrs = permitted.slice(:name, :kind, :enabled).to_h
      attrs[:config] = { "url" => permitted[:webhook_url].to_s }
      attrs[:webhook_secret] = permitted[:webhook_secret] if permitted[:webhook_secret].present?
      attrs
    end
  end
end
