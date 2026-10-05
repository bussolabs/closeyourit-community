# frozen_string_literal: true

module Cli
  module V1
    # Piattaforme (lookup org-scoped, Types::Platform) dell'organizzazione del token. Lettura gated da
    # `platforms.view` (chi gestisce con `platforms.manage` vede sempre) — specchio del canale Member;
    # create/update/destroy gated da `platforms.manage` (org-level). Scoping org via `org_platforms` →
    # un id/code di un'altra org dà R404 (anti-BOLA). La risoluzione del path è id-OR-code (il backend
    # accetta entrambi), sempre dentro lo scope org. CRUD banale su model, identica al canale Member.
    class PlatformsController < Cli::V1::BaseController
      before_action :require_platforms_view, only: %i[index show]
      before_action :set_platform, only: %i[show update destroy]
      before_action :require_platforms_management, only: %i[create update destroy]

      def index
        records, meta = paginate(org_platforms.ordered)
        render_ok(PlatformSerializer.new(records), meta: meta)
      end

      def show
        render_ok(PlatformSerializer.new(@platform))
      end

      def create
        platform = org_platforms.new(platform_params)
        platform.created_by = Current.account
        if platform.save
          render_created(PlatformSerializer.new(platform))
        else
          render_platform_error(platform)
        end
      end

      def update
        if @platform.update(platform_params)
          render_ok(PlatformSerializer.new(@platform))
        else
          render_platform_error(@platform)
        end
      end

      def destroy
        if @platform.destroy
          render_no_content
        else
          render_platform_error(@platform)
        end
      end

      private

      # Anti-BOLA: risolve per id O code, ma sempre dentro lo scope org; fuori scope (o sconosciuto) →
      # RecordNotFound → R404 centralizzato. find_by(id:) su PK uuid casta un code non-uuid a nil (uuid
      # type), quindi cade in sicurezza sul lookup per code.
      def set_platform
        @platform = org_platforms.find_by(id: params[:id]) || org_platforms.find_by(code: params[:id])
        raise ActiveRecord::RecordNotFound unless @platform
      end

      def org_platforms
        Current.organization.platforms
      end

      # Stessi attributi del canale Member (Member::PlatformsController#platform_params): supports_uptime
      # abilita l'uptime sui progetti che dichiarano questa piattaforma.
      def platform_params
        params.permit(:code, :label, :color, :position, :active, :supports_uptime)
      end

      def render_platform_error(platform)
        render_error("R422-PLATFORM-001", platform.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: platform.errors.to_hash)
      end

      # Lettura (index/show): gata da platforms.view; chi gestisce (platforms.manage) vede sempre.
      def require_platforms_view
        require_permission!("platforms.view") unless authorization.can?("platforms.manage")
      end

      def require_platforms_management
        require_permission!("platforms.manage")
      end
    end
  end
end
