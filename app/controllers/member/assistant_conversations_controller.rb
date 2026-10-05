# frozen_string_literal: true

module Member
  # Chat con l'assistente help. Dati posseduti dall'utente → nessun require_permission!: lo scope è
  # l'ownership (Assistant::Conversation.for nell'org corrente), che è anche il confine anti-BOLA 404.
  # Controller FLAT (non Member::Assistant::) per non ombreggiare il namespace di dominio ::Assistant.
  class AssistantConversationsController < Member::BaseController
    permission_not_required "Conversazioni con l'assistente possedute dall'utente: lo scope per account è anche il " \
                            "confine anti-BOLA."

    before_action :set_conversation, only: %i[show]

    def index
      # CYRA-684 — le conversazioni si accumulano senza limite: a pagine, non tutte in una volta.
      @query = params[:q].to_s.strip
      @pagination = paginate(listed_conversations)
      @conversations = @pagination.records
      ids = @conversations.map(&:id)
      @message_counts = Assistant::Message.where(conversation_id: ids).group(:conversation_id).count
      @last_answers = last_answers_for(ids)
    end

    def show
      @messages = @conversation.messages.chronological.includes(:proposals)
      @project = visible_project(@conversation.project_id)
    end

    # Corpo del pannello flottante, caricato lazy dal turbo-frame del FAB. SOLA LETTURA (GET idempotente,
    # nessuna scrittura → niente race né righe fantasma da prefetch): mostra la conversazione più recente,
    # o l'empty-state se non ce ne sono. La conversazione nasce con un POST — dal "+" o dal primo invio.
    def panel
      unless ::Ai::Configuration.current.chat_configured?
        return render(partial: "member/assistant_conversations/not_configured")
      end

      # Opened from a project: the latest conversation fixed on it, or an empty panel that will
      # create one. Opened from the top bar: the latest of all, with its project if it has one.
      project = visible_project(params[:project_id])
      @conversation = (project ? scope.where(project_id: project.id) : scope).ordered.first
      @messages = @conversation ? @conversation.messages.chronological.includes(:proposals) : []
      render partial: "member/assistant_conversations/panel",
             locals: { conversation: @conversation, messages: @messages,
                       project: project || visible_project(@conversation&.project_id) }
    end

    # Nuova conversazione (dal "+" o dal primo invio quando non ce ne sono): POST. Se arriva del testo lo
    # posta subito. Nel pannello rimpiazza il frame sulla conversazione fresca; altrove redirige alla show.
    def create
      project = visible_project(params[:project_id])
      conversation = scope.create!(project: project)
      Assistant::PostMessage.call(conversation: conversation, text: params[:text]) if params[:text].present?

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace("assistant_panel",
            partial: "member/assistant_conversations/panel",
            locals: { conversation: conversation, project: project,
                      messages: conversation.messages.chronological.includes(:proposals) })
        end
        format.html { redirect_to member_assistant_conversation_path(conversation) }
      end
    end

    private

    def scope
      Assistant::Conversation.for(account: Current.account, organization: Current.organization)
    end

    # Conversations with at least one message (an empty one only appears after pressing "+"),
    # optionally narrowed to the titles that contain the query.
    def listed_conversations
      conversations = scope.ordered.where.not(last_message_at: nil)
      return conversations if @query.blank?

      conversations.where("title ILIKE ?", "%#{Assistant::Conversation.sanitize_sql_like(@query)}%")
    end

    # Latest complete assistant answer per conversation, for the preview line: one query.
    def last_answers_for(conversation_ids)
      return {} if conversation_ids.empty?

      Assistant::Message.where(conversation_id: conversation_ids, role: :assistant, status: :complete)
                        .select("DISTINCT ON (conversation_id) assistant_messages.*")
                        .reorder(:conversation_id, created_at: :desc)
                        .index_by(&:conversation_id)
    end

    # The project a conversation is fixed on, only while the account can still see it.
    def visible_project(id)
      visible.projects.find_by(id: id) if id.present?
    end

    def set_conversation
      @conversation = scope.find(params[:id])
    end
  end
end
