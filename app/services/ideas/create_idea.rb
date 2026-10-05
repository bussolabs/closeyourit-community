# frozen_string_literal: true

module Ideas
  # Crea un'idea su un progetto visibile all'autore (anti-BOLA via VisibleScope, come
  # Ticketing::CreateTicket). Le validazioni tenant finali restano nel model. Result pattern.
  class CreateIdea < ApplicationService
    def initialize(organization:, author:, params:, true_actor: nil)
      @organization = organization
      @author = author
      @params = params
      @true_actor = true_actor
    end

    def call
      project = visible_projects.find_by(id: @params[:project_id])
      return Result.err(AppError.new(I18n.t("ideas.errors.project_not_found"), code: "R404-IDEA-001")) if project.nil?

      # CYRA-845 — evoluzione: l'idea di base si risolve DENTRO il progetto già visibile (anti-BOLA);
      # un id di un altro progetto/org → stesso 404 di un progetto invisibile, mai un leak.
      base = nil
      if @params[:evolves_id].present?
        base = project.ideas.find_by(id: @params[:evolves_id])
        return Result.err(AppError.new(I18n.t("ideas.errors.base_not_found"), code: "R404-IDEA-002", status: :not_found)) if base.nil?
      end

      idea = project.ideas.new(title: @params[:title], problem: @params[:problem],
                               solution: @params[:solution], stakeholders: @params[:stakeholders],
                               monetization: @params[:monetization], risks: @params[:risks],
                               author: @author)
      # Salvataggio + evento di attività atomici (audit all-or-nothing). La notifica resta FUORI dalla
      # transazione: si accoda solo a commit avvenuto, altrimenti un rollback lascerebbe in coda
      # l'avviso di un'idea che non esiste.
      ApplicationRecord.transaction do
        idea.save!
        # Il filo verso la base nasce con l'idea: se il collegamento è rifiutato (base già figlia di
        # un'altra), l'idea non nasce affatto — un'evoluzione orfana sarebbe un'idea qualsiasi.
        link_to_base!(idea, base) if base
        Activity::Record.call(subject: idea, action: "created", actor: @author, true_actor: @true_actor)
      end
      notify_created(idea)
      # CYRA-167 — indicizzazione per la ricerca per significato e per i doppioni suggeriti. Fuori
      # transazione come la notifica: un rollback lascerebbe in coda l'embed di un'idea inesistente.
      Ideas::EmbedIdeaJob.perform_later(idea_id: idea.id)
      Result.ok(idea)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(I18n.t("ideas.errors.invalid"),
                              code: "R422-IDEA-001", details: e.record.errors.to_hash))
    end

    private

    def link_to_base!(idea, base)
      Ideas::Link.create!(source: idea, target: base, kind: :evolution)
    end

    # CYRA-147: avvisa chi vede il progetto (autore escluso via actor_id) riusando la pipeline rule-based.
    # Enqueue DOPO il save committato, su coda :alerts — come i ticket accodano il NotifyJob a valle della
    # mutazione. Senza una regola idea_created attiva nell'org, Evaluate è un no-op.
    def notify_created(idea)
      Alerting::EvaluateJob.perform_later(
        event_type: "idea_created", subject_type: "Ideas::Idea", subject_id: idea.id,
        project_id: idea.project_id, actor_id: @author&.id
      )
    end

    # Progetti su cui l'autore può proporre idee → fonte unica di visibilità (link personali
    # + dei team). SOLO owner (+god) vedono tutti; gli altri solo i collegati (strict).
    def visible_projects
      Authorization::VisibleScope.new(account: @author, organization: @organization).projects
    end
  end
end
