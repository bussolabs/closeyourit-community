# frozen_string_literal: true

module Ideas
  # Aggiorna titolo/corpo di un'idea APERTA (le idee converted/archived sono congelate).
  # L'idea arriva già risolta e scoped dal controller. Result pattern.
  class UpdateIdea < ApplicationService
    def initialize(idea:, params:, actor: nil, true_actor: nil)
      @idea = idea
      @params = params
      @actor = actor
      @true_actor = true_actor
    end

    def call
      return Result.err(AppError.new(I18n.t("ideas.errors.locked"), code: "R422-IDEA-002")) if @idea.locked?
      updates = { title: @params[:title], problem: @params[:problem], solution: @params[:solution] }
      # stakeholders, monetizzazione e rischi solo se il canale li ha inviati (evita di azzerarli su
      # update parziali dalla CLI; il form web li manda sempre).
      %i[stakeholders monetization risks].each do |field|
        updates[field] = @params[field] if @params.key?(field)
      end

      ApplicationRecord.transaction do
        @idea.update!(updates)
        record_activity
      end
      # CYRA-167 — re-embed SOLO se è cambiato il testo semantico (titolo/problema/soluzione): gli
      # stakeholder non entrano nel vettore, e ri-embeddare a ogni salvataggio sarebbe una chiamata di
      # rete per niente. Fuori transazione, mai after_commit.
      if (@idea.saved_changes.keys & Ideas::EmbeddingText::WATCHED_COLUMNS).any?
        Ideas::EmbedIdeaJob.perform_later(idea_id: @idea.id)
      end
      Result.ok(@idea)
    rescue ActiveRecord::RecordInvalid
      Result.err(AppError.new(I18n.t("ideas.errors.invalid"),
                              code: "R422-IDEA-001", details: @idea.errors.to_hash))
    end

    private

    # 'updated' solo se sono cambiate colonne reali (niente evento-rumore su submit senza modifiche).
    def record_activity
      changed = @idea.saved_changes.keys - %w[updated_at created_at]
      return if changed.empty?

      Activity::Record.call(subject: @idea, action: "updated", data: { fields: changed },
                            actor: @actor, true_actor: @true_actor)
    end
  end
end
