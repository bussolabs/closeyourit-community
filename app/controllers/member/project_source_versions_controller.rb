# frozen_string_literal: true

module Member
  # Cronologia versioni di una fonte OSSERVATA (Projects::Source) della card "Monitoring tools": le
  # versioni viste del tool nel tempo, dalla data di optin a quella di optout verso la versione nuova.
  # Controller flat (non Member::Projects::* per non ombreggiare il namespace ::Projects). Lettura =
  # visibilità del progetto (nessuna key, come la card tool); anti-BOLA su progetto e fonte.
  class ProjectSourceVersionsController < Member::BaseController
    permission_not_required "Versioni viste di uno strumento osservato: sola lettura, il confine è la visibilità del " \
                            "progetto."

    before_action :set_project
    before_action :set_source

    def index
      # CYRA-684 — una versione per rilascio: la lista cresce per sempre, si legge a pagine.
      @pagination = paginate(@source.versions.chronological)
      @versions = @pagination.records
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    # Fonte scoped al progetto: id di una source altrui → RecordNotFound (anti-IDOR).
    def set_source
      @source = @project.sources.find(params[:source_id])
    end
  end
end
