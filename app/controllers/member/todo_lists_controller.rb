# frozen_string_literal: true

module Member
  # Liste di todo personali dell'area web. Dati posseduti dall'utente → nessun require_permission!:
  # lo scope è l'ownership (Current.account.todo_lists nell'org corrente). La show ammette anche le
  # liste CONDIVISE con me (sola lettura, @can_edit = false); modifica/eliminazione solo sulle proprie.
  class TodoListsController < Member::BaseController
    permission_not_required "Liste di cose da fare personali: il confine è la proprietà; le liste condivise si " \
                            "leggono soltanto."

    before_action :set_visible_list, only: %i[show]
    before_action :set_owned_list, only: %i[edit update destroy]

    def index
      @query = params[:q].to_s.strip
      @lists = search_lists(owned_lists).ordered.includes(:items, shares: :account)
      @shared_lists = search_lists(shared_lists).ordered.includes(:items, :account)
    end

    def show
      @items = @list.items.ordered.includes(ticket: :project)
      return unless @can_edit

      @shared_names = @list.shared_accounts.order(:name).pluck(:name)
      # The share dialog lives on this page; the sharing page keeps working for direct links.
      @members = Current.organization.accounts.human.where.not(id: Current.account.id).order(:name)
      @selected = @list.shares.pluck(:account_id)

      # Ticket collegabili (CYRA-364): le poche voci toccate di recente, non i cento dell'intera
      # organizzazione. Digitando, il campo si rifornisce dal server (member/tickets/linkable).
      @linkable_tickets = ::Ticketing::LinkableTickets.call(scope: visible.tickets)
    end

    def new
      @list = owned_lists.build
    end

    def create
      @list = owned_lists.build
      result = Todos::Lists::Save.call(list: @list, attributes: list_params)
      if result.ok?
        redirect_to (params[:from] == "index" ? member_todo_lists_path(focus: result.value.id) : member_todo_list_path(result.value)),
                    notice: t("member.todo_lists.created")
      elsif params[:from] == "index"
        redirect_to member_todo_lists_path, alert: @list.errors.full_messages.to_sentence
      else
        @errors = @list.errors.to_hash
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      result = Todos::Lists::Save.call(list: @list, attributes: list_params)
      if result.ok?
        redirect_to member_todo_list_path(@list), notice: t("member.todo_lists.updated")
      else
        @errors = @list.errors.to_hash
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @list.destroy
      redirect_to member_todo_lists_path, notice: t("member.todo_lists.deleted")
    end

    def reorder
      Todos::Lists::Reorder.call(account: Current.account, organization: Current.organization,
                                 ordered_ids: params[:ordered_ids])
      head :ok
    end

    private

    def search_lists(scope)
      return scope if @query.blank?

      pattern = "%#{Todos::List.sanitize_sql_like(@query)}%"
      matching_items = Todos::Item.where("title ILIKE ?", pattern).select(:list_id)
      scope.where("name ILIKE ?", pattern).or(scope.where(id: matching_items))
    end

    def owned_lists
      Todos::List.for(account: Current.account, organization: Current.organization)
    end

    def shared_lists
      Todos::List.shared_with(Current.account).where(organization_id: Current.organization.id)
    end

    # show: la lista dev'essere posseduta OPPURE condivisa con me → altrimenti 404 (anti-BOLA).
    def set_visible_list
      lists = Todos::List.where(id: owned_lists.select(:id)).or(Todos::List.where(id: shared_lists.select(:id)))
      @list = lists.find(params[:id])
      @can_edit = @list.account_id == Current.account.id
    end

    # edit/update/destroy: solo sulle liste possedute (una condivisa è read-only) → altrui = 404.
    def set_owned_list
      @list = owned_lists.find(params[:id])
    end

    def list_params
      params.permit(:name, :color)
    end
  end
end
