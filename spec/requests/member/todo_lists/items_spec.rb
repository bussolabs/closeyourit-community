# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::TodoLists::Items", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:list) { create(:todo_list, account:, organization: org) }

  before { create(:membership, account:, organization: org, role: :member) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  # The markup inside the turbo-stream templates (Capybara does not read <template> content).
  def stream_html
    Capybara.string(response.body.scan(%r{<template>(.*?)</template>}m).flatten.join)
  end

  def progress_text(done, total)
    I18n.t("member.todo_lists.progress_header", done:, total:)
  end

  describe "POST create" do
    it "aggiunge la voce e reindirizza alla lista" do
      sign_in(account)
      expect do
        post member_todo_list_items_path(list), params: { title: "Fix login" }
      end.to change(Todos::Item, :count).by(1)
      expect(response).to redirect_to(member_todo_list_path(list))
    end

    it "ticket di un'altra org → non crea, alert" do
      sign_in(account)
      alien = create(:ticket, organization: create(:organization))
      expect do
        post member_todo_list_items_path(list), params: { title: "X", ticket_id: alien.id }
      end.not_to change(Todos::Item, :count)
      expect(response).to redirect_to(member_todo_list_path(list))
      follow_redirect!
      expect(response.body).to include("todo-list") # la show ricarica, l'item non c'è
    end

    it "lista altrui → 404 (anti-BOLA)" do
      sign_in(account)
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :member)
      foreign = create(:todo_list, account: owner, organization: org)
      post member_todo_list_items_path(foreign), params: { title: "X" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH toggle" do
    it "spunta la voce (done true→completed)" do
      sign_in(account)
      item = create(:todo_item, list:, done: false)
      patch toggle_member_todo_list_item_path(list, item)
      expect(item.reload.done?).to be(true)
      expect(item.completed_at).to be_present
    end

    it "ri-spunta riapre la voce" do
      sign_in(account)
      item = create(:todo_item, :done, list:)
      patch toggle_member_todo_list_item_path(list, item)
      expect(item.reload.done?).to be(false)
    end

    it "toggle via turbo_stream → renderizza il partial della voce (formato turbo_stream)" do
      sign_in(account)
      item = create(:todo_item, list:, done: false)
      patch toggle_member_todo_list_item_path(list, item), as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    end

    # CYRA-828 — riga e riepilogo sono lo stesso fatto: se lo stream porta solo la riga, il conteggio
    # delle completate resta indietro fino al ricaricamento della pagina.
    # Page refactor (2026-10-01): a ticked item moves to the Completed group, so the stream redraws
    # the whole items block (morph keeps focus) instead of the single row.
    it "turbo_stream: aggiorna la riga E il riepilogo nello stesso scambio" do
      sign_in(account)
      item = create(:todo_item, list:, done: false)
      create(:todo_item, list:, done: false)

      patch toggle_member_todo_list_item_path(list, item), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(target="todo_items"))
      expect(response.body).to include(%(target="todo_list_stats"))
      expect(response.body).to include(progress_text(1, 2))
    end

    it "turbo_stream: riaprire una voce riporta indietro il riepilogo" do
      sign_in(account)
      item = create(:todo_item, :done, list:)

      patch toggle_member_todo_list_item_path(list, item), as: :turbo_stream

      expect(response.body).to include(%(target="todo_list_stats"))
      expect(response.body).to include(progress_text(0, 1))
    end

    it "turbo_stream: una lista con una sola voce arriva a 1/1" do
      sign_in(account)
      item = create(:todo_item, list:, done: false)

      patch toggle_member_todo_list_item_path(list, item), as: :turbo_stream

      expect(response.body).to include(progress_text(1, 1))
    end

    context "quando il salvataggio viene rifiutato" do
      # Il progetto del ticket collegato migra in un'altra organizzazione: da lì in poi la voce non
      # supera più la validazione tenant e la spunta non si salva.
      let(:item) do
        create(:todo_item, list:, done: false, ticket: create(:ticket, organization: org)).tap do |todo|
          todo.ticket.project.update_column(:organization_id, create(:organization).id)
        end
      end

      it "turbo_stream: 422, riga e riepilogo restano su ciò che è salvato, messaggio a schermo" do
        sign_in(account)

        patch toggle_member_todo_list_item_path(list, item), as: :turbo_stream

        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.done?).to be(false)
        expect(response.body).to include(progress_text(0, 1))
        # A filled checkbox would mean the stream confirms a state the database does not have.
        checkbox = stream_html.find("[data-test='todo-item-toggle-#{item.id}'] span")
        expect(checkbox[:class]).not_to include("bg-indigo-600")
        expect(response.body).to include(I18n.t("todos.items.errors.invalid"))
      end

      it "senza turbo: alert e stato invariato" do
        sign_in(account)

        patch toggle_member_todo_list_item_path(list, item)

        expect(response).to redirect_to(member_todo_list_path(list))
        expect(flash[:alert]).to eq(I18n.t("todos.items.errors.invalid"))
        expect(item.reload.done?).to be(false)
      end
    end

    it "lista condivisa in sola lettura → 404 (la spunta non diventa modificabile)" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :member)
      shared = create(:todo_list, account: owner, organization: org)
      item = create(:todo_item, list: shared, done: false)
      create(:todo_share, list: shared, account:)

      sign_in(account)
      patch toggle_member_todo_list_item_path(shared, item), as: :turbo_stream

      expect(response).to have_http_status(:not_found)
      expect(item.reload.done?).to be(false)
    end
  end

  describe "PATCH update / DELETE destroy / reorder" do
    it "aggiorna il titolo" do
      sign_in(account)
      item = create(:todo_item, list:, title: "Vecchio")
      patch member_todo_list_item_path(list, item), params: { title: "Nuovo" }
      expect(item.reload.title).to eq("Nuovo")
    end

    it "update con titolo vuoto → alert (Save fallita), titolo invariato" do
      sign_in(account)
      item = create(:todo_item, list:, title: "Vecchio")
      patch member_todo_list_item_path(list, item), params: { title: "" }
      expect(response).to redirect_to(member_todo_list_path(list))
      expect(item.reload.title).to eq("Vecchio")
    end

    it "elimina la voce" do
      sign_in(account)
      item = create(:todo_item, list:)
      delete member_todo_list_item_path(list, item)
      expect(Todos::Item.exists?(item.id)).to be(false)
    end

    it "riordina le voci → 200" do
      sign_in(account)
      a = create(:todo_item, list:, position: 0)
      b = create(:todo_item, list:, position: 0)
      patch reorder_member_todo_list_items_path(list), params: { ordered_ids: [ b.id, a.id ] }
      expect(response).to have_http_status(:ok)
      expect(b.reload.position).to eq(0)
      expect(a.reload.position).to eq(1)
    end
  end

  describe "page refactor (2026-10-01)" do
    it "renaming an item keeps its linked ticket" do
      sign_in(account)
      ticket = create(:ticket, organization: org)
      item = create(:todo_item, list:, title: "Old", ticket:)

      patch member_todo_list_item_path(list, item), params: { title: "New" }

      expect(item.reload).to have_attributes(title: "New", ticket_id: ticket.id)
    end

    it "a ticked item lands in the Completed group" do
      sign_in(account)
      item = create(:todo_item, list:, done: false)

      patch toggle_member_todo_list_item_path(list, item), as: :turbo_stream

      expect(stream_html).to have_css("[data-test='todo-items-done'] ##{ActionView::RecordIdentifier.dom_id(item)}", visible: :all)
    end
  end
end
