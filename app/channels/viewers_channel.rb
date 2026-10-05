# frozen_string_literal: true

# Canale "viewers" per-risorsa (Task D2): conta in tempo reale "chi sta guardando" un ticket o un
# monitor e ne broadcasta il conteggio come Turbo Stream (replace del badge target `viewers_<gid>`).
#
# Una subscription = un tab aperto sulla show. `subscribed` registra il viewer (dedup per account nel
# registry TTL), fa `stream_from` lo stream della risorsa (così il broadcast torna al client → il
# controller Stimulus lo applica al DOM) e fa partire il primo broadcast. `unsubscribed` rimuove il
# viewer e ribroadcasta. `touch` (heartbeat dal controller Stimulus) rinfresca SOLO il TTL del viewer
# vivo — non ribroadcasta: i cambi di conteggio reali passano sempre da un sub/unsub; un viewer
# crashato scade per TTL e il conteggio si corregge al prossimo evento (correzione eventuale,
# accettabile per un indicatore ambientale).
#
# Sicurezza/tenant: la risorsa arriva come gid param NON firmato (Realtime::Streams usa to_gid_param).
# La risolviamo, la restringiamo alle sole classi consentite (ticket/monitor) e VALIDIAMO che il suo
# progetto appartenga alla current_organization (anti-BOLA). Il nome-stream è org-prefissato da
# Realtime::Streams → il broadcasting è isolato per tenant a livello di nome.
class ViewersChannel < ApplicationCable::Channel
  # Allowlist: solo le risorse che espongono il badge viewers. Evita di localizzare modelli arbitrari
  # a partire da un gid non firmato.
  ALLOWED_MODELS = [ "Ticketing::Ticket", "Uptime::Monitor" ].freeze

  def subscribed
    resource = resolve_resource
    return reject unless resource

    @resource = resource
    @stream = Realtime::Streams.viewers(current_organization, resource)
    @target = "viewers_#{resource.to_gid_param}"
    @token = SecureRandom.uuid

    stream_from @stream, coder: ActiveSupport::JSON do |message|
      if resolve_resource
        transmit(message)
      else
        stop_all_streams
        connection.close(reconnect: false)
      end
    end
    broadcast_count(Realtime::ViewersRegistry.register(@stream, token: @token, account_id: current_account.id))
  end

  # Heartbeat dal client: rinfresca il TTL del viewer corrente così un viewer che resta sulla pagina
  # non scade dopo DEFAULT_TTL. Nessun broadcast: il conteggio non cambia per un refresh.
  def touch
    return if @stream.blank? || !resolve_resource

    Realtime::ViewersRegistry.register(@stream, token: @token, account_id: current_account.id)
  end

  def unsubscribed
    return if @stream.blank?

    broadcast_count(Realtime::ViewersRegistry.unregister(@stream, token: @token))
  end

  private

  # Turbo replace del badge: ri-renderizza member/viewers/_count (id stabile = @target) col conteggio
  # nuovo. Reso da Ui::BadgeComponent + i18n member.presence.viewers_count.
  def broadcast_count(count)
    Turbo::StreamsChannel.broadcast_replace_to(
      @stream, target: @target,
      partial: "member/viewers/count", locals: { count: count, resource: @resource }
    )
  end

  # gid param (non firmato) → record, con blindatura tenant:
  #  1. parse valido + classe nell'allowlist (no localizzazione di modelli arbitrari)
  #  2. record esistente e con project della current_organization (anti-BOLA)
  # Qualunque violazione/errore → nil → reject.
  def resolve_resource
    return if current_organization.blank? || current_account.blank?

    account = connection.live_account
    return unless account

    gid = GlobalID.parse(params[:resource])
    return unless gid && ALLOWED_MODELS.include?(gid.model_name)

    resource = gid.find
    # simplecov:disable i modelli in allowlist (Ticket/Monitor) rispondono sempre a :project e hanno project obbligatorio →
    # gli arm `respond_to?(:project)` falso e `project&` nil sono irraggiungibili (difesa contro gid arbitrari).
    return unless resource.respond_to?(:project) && resource.project&.organization_id == current_organization.id
    # simplecov:enable

    visible = Authorization::VisibleScope.new(account: account, organization: current_organization)
    return unless visible.projects.exists?(id: resource.project_id)

    resource
  rescue StandardError
    nil
  end
end
