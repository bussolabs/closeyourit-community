# frozen_string_literal: true

module Api
  module V1
    # CYSK-29 — ingest della telemetria d'uso. SOLO bearer (Api::V1::BaseController, mai la DSN
    # public key): un canale usage scrivibile dal browser è un invito a inquinare la symbol table.
    # Un flush ogni ~5 minuti per processo: il payload porta la finestra, l'SDK e i simboli visti —
    # `route` è `Controller#action`, mai l'URL; niente user, path, parametri, IP.
    #
    # I simboli fuori contratto (formato o kind) si SCARTANO uno a uno senza bocciare il flush: la
    # semantica portante è `last_seen_at`, e perdere una finestra intera per una voce sporca
    # fabbricherebbe proprio i falsi «mai visti» che il canale esiste per evitare.
    class UsagesController < Api::V1::BaseController
      before_action -> { require_scope!(:ingest) }, only: :create
      before_action -> { require_scope!(:read) }, only: :index

      MAX_SYMBOLS_PER_FLUSH = 5000

      def index
        scope = ::Usage::Symbol.where(project_id: Current.project.id)
        scope = scope.where(kind: params[:kind]) if params[:kind].present?
        scope = scope.where(environment: params[:environment]) if params[:environment].present?
        records, meta = paginate(scope.order(last_seen_at: :desc, id: :desc))
        render_ok(UsageSymbolSerializer.new(records), meta:)
      end

      def create
        symbols = Array(params[:symbols]).map { |raw| raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw }
        if symbols.size > MAX_SYMBOLS_PER_FLUSH
          return render_error("R413-USAGE-001", "Flush di usage troppo grande", status: :content_too_large)
        end

        accepted = symbols.select { |item| acceptable?(item) }
        ::Usage::IngestJob.perform_later(
          project_id: Current.project.id,
          environment: params[:environment].to_s.presence || "production",
          sdk: { "name" => params.dig(:sdk, :name).to_s.presence || "unknown",
                 "version" => params.dig(:sdk, :version).to_s },
          release: params[:release].to_s.presence,
          truncated: ActiveModel::Type::Boolean.new.cast(params[:truncated]) || false,
          symbols: accepted
        )
        render json: { data: { accepted: accepted.size } }, status: :accepted
      end

      private

      def acceptable?(item)
        return false unless item.is_a?(Hash)

        kind = item["kind"].to_s
        symbol = item["symbol"].to_s
        ::Usage::Symbol::KINDS.include?(kind) && symbol.match?(::Usage::Symbol::SYMBOL_FORMAT)
      end
    end
  end
end
