# frozen_string_literal: true

module Member
  # Chat tra membri: lista conversazioni (DM + canali visibili), thread di una conversazione, apertura
  # (DM find-or-create per membro, oppure canale di un progetto/team). Controller FLAT: Member::Chat
  # ombreggerebbe il model namespace ::Chat. Scoping anti-BOLA via Chat::Conversation.visible_to.
  class ChatConversationsController < Member::BaseController
    permission_not_required "Chat fra membri: il confine è la visibilità della conversazione " \
                            "(Chat::Conversation.visible_to)."

    before_action :set_conversation, only: %i[show taggable]

    def index
      load_conversations_pane
      load_new_conversation_picker
    end

    def show
      # Ai canali si accede in modo relazionale: la riga partecipante (stato letto/muto) si crea lazy.
      # mark_read! PRIMA del pane: la conversazione aperta non deve mostrare il proprio badge non letti.
      @participant = Chat::Participant.ensure_for(conversation: @conversation, account: Current.account)
      @participant.mark_read!
      load_conversations_pane
      load_new_conversation_picker
      @messages = @conversation.messages.kept.chronological.includes(:author, references: :referable)
      preload_ticket_reference_details(@messages)
      # Revoca live: i riferimenti a risorse su cui il viewer ha PERSO l'accesso si oscurano al render.
      @visible_project_ids = Authorization::VisibleScope
                             .new(account: Current.account, organization: Current.organization)
                             .projects.pluck(:id)
      @message = Chat::Message.new
      @people_count = @conversation.audience.size
    end

    def create
      result = open_conversation
      if result.ok?
        redirect_to member_chat_conversation_path(result.value)
      else
        redirect_to member_chat_conversations_path, alert: result.error.message
      end
    end

    # Autocomplete del picker: risorse taggabili nell'intersezione dei partecipanti (in comune).
    def taggable
      resources = Chat::Taggables::Search.call(conversation: @conversation, query: params[:q], type: params[:type])
      render json: { data: resources }
    end

    private

    # Pane sinistro (lista + badge non letti) condiviso da index e show.
    # includes: title_for legge accounts (DM) e contextable (canali) per ogni riga → senza preload è N+1.
    def load_conversations_pane
      @conversations = visible_conversations.ordered.includes(:contextable, :accounts)
      @unread_by_conversation = Chat::Conversation.unread_counts_for(
        account: Current.account, conversation_ids: @conversations.map(&:id)
      )
      @unread_total = @unread_by_conversation.values.sum
      @conversations_total = @conversations.size
      @unread_only = params[:unread].present?
      @conversations = @conversations.select { |c| @unread_by_conversation[c.id] } if @unread_only
      @last_messages = last_messages_for(@conversations.map(&:id))
    end

    # Latest kept message per conversation, for the preview line under each name: one query.
    def last_messages_for(conversation_ids)
      return {} if conversation_ids.empty?

      Chat::Message.kept.where(conversation_id: conversation_ids)
                   .select("DISTINCT ON (conversation_id) chat_messages.*")
                   .order(:conversation_id, created_at: :desc)
                   .includes(:author).index_by(&:conversation_id)
    end

    # Sorgenti del dialog "nuova conversazione" (nell'header condiviso da index e show): tutti i membri
    # org (il gate ≥1 progetto comune resta nel service — filtrare qui costerebbe N×VisibleScope),
    # progetti visibili, team di appartenenza.
    def load_new_conversation_picker
      @members = member_accounts.where.not(id: Current.account.id).order(:name)
      @pickable_projects = visible.projects.order(:name)
      @teams = visible.teams.order(:name)
    end

    def visible_conversations
      Chat::Conversation.visible_to(account: Current.account, organization: Current.organization)
    end

    # Anti-BOLA: conversazione non visibile (o di altra org) → RecordNotFound (404).
    def set_conversation
      @conversation = visible_conversations.find(params[:id])
    end

    def open_conversation
      case params[:kind]
      when "direct" then open_direct
      when "project" then open_channel(visible.projects.find(params[:project_id]))
      when "team" then open_channel(visible.teams.find(params[:team_id]))
      else Result.err(AppError.new(I18n.t("chat.errors.invalid_context"), code: "R422-CHAT-005"))
      end
    end

    def open_direct
      other = member_accounts.find(params[:account_id])
      Chat::Conversations::FindOrCreateDirect.call(
        organization: Current.organization, account_a: Current.account, account_b: other, actor: Current.account
      )
    end

    def open_channel(contextable)
      Chat::Conversations::FindOrCreateChannel.call(
        organization: Current.organization, contextable: contextable, actor: Current.account
      )
    end

    # Membri dell'org (anti-BOLA: un id non-membro → 404).
    def member_accounts
      Accounts::Account.where(id: Connections::Membership.where(organization_id: Current.organization.id).select(:account_id))
    end

    # La card di un ticket taggato legge project (code) e status (badge): secondo livello non coperto
    # dall'includes(references: :referable) → preload esplicito, o è 2 query per reference.
    def preload_ticket_reference_details(messages)
      tickets = messages.flat_map(&:references).map(&:referable).grep(Ticketing::Ticket)
      return if tickets.empty?

      ActiveRecord::Associations::Preloader.new(records: tickets, associations: %i[project status]).call
    end
  end
end
