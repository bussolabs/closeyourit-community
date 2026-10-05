# frozen_string_literal: true

module Member
  module TodoLists
    # Voci di una lista posseduta (area web). set_list è scoped all'ownership → una lista condivisa
    # (read-only) o altrui dà 404: non si mutano voci di liste non proprie. toggle = spunta inline
    # (turbo_stream), reorder = drag-drop.
    class ItemsController < Member::BaseController
      permission_not_required "Voci di una lista propria: una lista altrui, o condivisa in sola lettura, dà 404."

      before_action :set_list
      before_action :set_item, only: %i[update destroy toggle]

      def create
        result = Todos::Items::Save.call(item: @list.items.build, attributes: item_params)
        if result.ok?
          redirect_to back_path(focus: true), notice: t("member.todo_lists.item.created")
        else
          redirect_to back_path, alert: item_error_message(result.error)
        end
      end

      def update
        result = Todos::Items::Save.call(item: @item, attributes: item_params)
        if result.ok?
          redirect_to member_todo_list_path(@list), notice: t("member.todo_lists.item.updated")
        else
          redirect_to member_todo_list_path(@list), alert: item_error_message(result.error)
        end
      end

      def destroy
        @item.destroy
        redirect_to back_path, notice: t("member.todo_lists.item.deleted")
      end

      # CYRA-828 — la spunta e il numero delle voci completate sono lo stesso fatto: se lo scambio
      # porta solo la riga, il riepilogo in testata resta indietro fino al ricaricamento. Il Result
      # NON si ignora: un salvataggio rifiutato ridipingerebbe la casella su uno stato che il
      # database non ha.
      def toggle
        result = Todos::Items::Toggle.call(item: @item)
        # Il save fallito lascia done/completed_at sporchi in memoria: la riga deve raccontare ciò
        # che è salvato, non ciò che si è tentato.
        @item.restore_attributes unless result.ok?
        return redirect_to(back_path, alert: (result.error.message unless result.ok?)) if from_index?

        respond_to do |format|
          format.turbo_stream do
            flash.now[:alert] = result.error.message unless result.ok?
            render turbo_stream: toggle_streams(failed: !result.ok?),
                   status: result.ok? ? :ok : :unprocessable_content
          end
          format.html do
            if result.ok?
              redirect_to member_todo_list_path(@list)
            else
              redirect_to member_todo_list_path(@list), alert: result.error.message
            end
          end
        end
      end

      def reorder
        Todos::Items::Reorder.call(list: @list, ordered_ids: params[:ordered_ids])
        head :ok
      end

      private

      # Riga + riepilogo nello stesso scambio, e il messaggio solo quando c'è qualcosa da dire.
      # `method: :morph`: Turbo tocca solo ciò che è davvero cambiato, così il focus sulla casella
      # appena premuta e il punto di lettura restano dove sono.
      def toggle_streams(failed:)
        # Il conteggio si rilegge DOPO il salvataggio: reset perché arrivi dal database e non da una
        # collezione caricata prima del cambio.
        @list.items.reset
        streams = [
          # The whole block, not the row: a ticked item moves to the Completed group.
          turbo_stream.replace("todo_items", method: :morph,
                               partial: "member/todo_lists/items",
                               locals: { list: @list, items: items_for_stream, can_edit: true }),
          turbo_stream.replace("todo_list_stats", method: :morph,
                               partial: "member/todo_lists/stats",
                               locals: { list: @list, can_edit: true })
        ]
        streams << turbo_stream.replace("flash-container", partial: "shared/flash") if failed
        streams
      end

      # The saved state of every item, except the toggled one, which may hold a refused change undone in
      # memory (restore_attributes): that instance is used as is.
      def items_for_stream
        @list.items.includes(ticket: :project).map { |item| item.id == @item.id ? @item : item }
      end

      # The index panels edit a list in place: their forms carry from=index and come back there, inside
      # the panel's frame. focus puts the cursor back in the add field of the list just extended.
      def from_index? = params[:from] == "index"

      def back_path(focus: false)
        return member_todo_list_path(@list) unless from_index?

        member_todo_lists_path(**{ q: params[:q].presence, focus: (@list.id if focus) }.compact)
      end

      def set_list
        @list = Todos::List.for(account: Current.account, organization: Current.organization)
                           .find(params[:todo_list_id])
      end

      def set_item
        @item = @list.items.find(params[:id])
      end

      def item_params
        params.permit(:title, :ticket_id)
      end

      # Ticket di un'altra org → messaggio dedicato; altrimenti messaggio generico del service.
      def item_error_message(error)
        # simplecov:disable Todos::Items::Save valorizza SEMPRE details con errors.to_hash (Hash) → il ramo
        # `error.details&` nil è irraggiungibile in questo canale.
        error.details&.key?(:ticket) ? t("member.todo_lists.item.invalid_ticket") : error.message
        # simplecov:enable
      end
    end
  end
end
