# frozen_string_literal: true

module Cli
  module V1
    # Idee del progetto: lettura, proposta, modifica ed eliminazione. Proporre un'idea è baseline (chi
    # vede il progetto può); Ideas::CreateIdea ri-verifica la visibilità (R404-IDEA-001) e isola org/scope
    # (anti-BOLA). Modifica/eliminazione di un'idea altrui gated (ideas.edit / ideas.delete), l'autore
    # resta padrone della propria idea aperta — specchio di Member::IdeasController. Scope CLI v1:
    # list/show/create/update/destroy + vote/comments/cases/conversion/archive nested. Logica nei service
    # Ideas::*, condivisa col canale Member (`rules/backend-channels.md`): qui solo auth/serializzazione.
    class IdeasController < Cli::V1::BaseController
      before_action :set_project!
      before_action :set_idea, only: %i[show update destroy]
      before_action :require_edit_permission, only: :update
      before_action :require_delete_permission, only: :destroy

      def index
        records, meta = paginate(scoped_ideas)
        render_ok(IdeaSerializer.new(records), meta: meta)
      end

      def show
        render_ok(IdeaSerializer.new(@idea))
      end

      def create
        result = ::Ideas::CreateIdea.call(
          organization: Current.organization, author: Current.account,
          params: idea_params.merge(project_id: @project.id)
        )
        if result.ok?
          render_created(IdeaSerializer.new(result.value))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      # PUT = full replace (come i ticket): title/problem/solution vengono riscritti dai params —
      # omettere `problem` la svuota → R422 (fail-safe). `stakeholders` è sostituito solo se inviato
      # (il service non azzera su update parziali). Il congelamento (converted/archived) è garantito
      # da Ideas::UpdateIdea (R422-IDEA-002).
      def update
        result = ::Ideas::UpdateIdea.call(idea: @idea, params: idea_params)
        if result.ok?
          render_ok(IdeaSerializer.new(result.value))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        @idea.destroy
        render_no_content
      end

      private

      # L'autore modifica sempre la propria idea; sulle idee altrui serve ideas.edit sul progetto.
      # Specchio di Member::IdeasController#require_idea_permission e delle conversion CLI.
      def require_edit_permission
        return if @idea.authored_by?(Current.account)

        require_permission!("ideas.edit", scope: @project)
      end

      # L'autore elimina sempre la propria idea; su quelle altrui serve ideas.delete sul progetto
      # (specchio di Member::IdeasController: destroy → ideas.delete).
      def require_delete_permission
        return if @idea.authored_by?(Current.account)

        require_permission!("ideas.delete", scope: @project)
      end

      # Anti-BOLA: l'idea si risolve DENTRO @project (già ristretto a visible_projects da
      # set_project!); un'idea di un altro progetto/org → RecordNotFound → R404 (mai leak).
      def set_idea
        @idea = @project.ideas.find(params[:id])
      end

      # Filtro opzionale ?status=open (enum name) + ordinamento per ultimo movimento (default,
      # come la bacheca web dopo CYRA-360: il voto non ordina più niente) o per creazione con
      # ?sort=recent, che resta perché è una scelta esplicita del client, non un default finto.
      # includes(:author): il serializer espone il nome dell'autore (no N+1, guard prosopite).
      def scoped_ideas
        scope = @project.ideas.includes(:author, :parent, :evolutions, :related_out, :related_in)
        statuses = Array(params[:status]).reject(&:blank?)
        scope = scope.where(status: statuses) if statuses.any?
        params[:sort] == "recent" ? scope.recent : scope.by_last_activity
      end

      def idea_params
        # CYRA-845 — monetization/risks come solution; evolves_id solo in create (idea di base).
        params.permit(:title, :problem, :solution, :monetization, :risks, :evolves_id, stakeholders: [])
      end
    end
  end
end
