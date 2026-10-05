# frozen_string_literal: true

module Cli
  module V1
    module Ideas
      # Conversione idea → ticket via CLI (PUT, idempotente sul già-convertito → R422-IDEA-003).
      # Converte l'autore (sempre) o chi ha `ideas.convert` sul progetto. Se title/description
      # mancano, la bozza viene sintetizzata INLINE dall'AI (idea + commenti): la CLI aspetta la
      # risposta — niente polling lato client. Con title+description espliciti l'AI non viene chiamata.
      #
      # CYRA-275: la sintesi gira su una chiamata strutturata al server AI (era Proxanything
      # 202+polling, worst ~730s). Il canale CLI resta SINCRONO, non
      # job+poll come il web: uno script a riga di comando non guadagna da un polling lato client, e
      # il traffico CLI è puntuale — non satura i thread web come le domande concorrenti del browser.
      class ConversionsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_idea
        before_action :require_convert_permission

        def update
          draft = draft_params
          return if performed? # sintesi AI fallita → errore già renderizzato

          result = ::Ideas::PromoteToTicket.call(
            idea: @idea, reporter: Current.account, true_actor: Current.account, params: draft
          )
          if result.ok?
            render_created(TicketSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        private

        def set_idea
          @idea = @project.ideas.find(params[:idea_id])
        end

        def require_convert_permission
          return if @idea.authored_by?(Current.account)

          require_permission!("ideas.convert", scope: @project)
        end

        # title+description espliciti → passthrough; altrimenti sintesi AI inline. La sintesi gira
        # SOLO su idee aperte (su congelate PromoteToTicket fallirebbe comunque: guard prima, così
        # non si paga una chiamata LLM per un esito già negato).
        def draft_params
          explicit = params.permit(:title, :description, :kind, :status_id, :priority_id)
          return explicit if explicit[:title].present? && explicit[:description].present?
          unless @idea.status_open?
            code = @idea.status_converted? ? "R422-IDEA-003" : "R422-IDEA-002"
            key = @idea.status_converted? ? "already_converted" : "locked"
            return render_error(code, I18n.t("ideas.errors.#{key}"), status: :unprocessable_content)
          end

          synthesis = ::Ideas::SynthesizeTicket.call(idea: @idea)
          if synthesis.err?
            return render_error(synthesis.error.code, synthesis.error.message, status: synthesis.error.status)
          end

          explicit.merge(
            title: explicit[:title].presence || synthesis.value.title,
            description: explicit[:description].presence || synthesis.value.description
          )
        end
      end
    end
  end
end
