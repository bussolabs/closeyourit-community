# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::TodoLists", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before { create(:membership, account:, organization: org, role: :member) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  describe "autenticazione" do
    it "non autenticato → redirect login" do
      get member_todo_lists_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET index" do
    it "mostra le mie liste e quelle condivise con me" do
      sign_in(account)
      mine = create(:todo_list, account:, organization: org, name: "Mia lista")

      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :member)
      shared = create(:todo_list, account: owner, organization: org, name: "Condivisa a me")
      create(:todo_share, list: shared, account:)

      get member_todo_lists_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Mia lista")
      expect(response.body).to include("Condivisa a me")
    end

    it "says which key adds an item, next to the field that has no button" do
      sign_in(account)
      create(:todo_list, account:, organization: org, name: "This week")

      get member_todo_lists_path

      hint = Nokogiri::HTML(response.body).at_css("[data-test='todo-panel-add-hint']")
      expect(hint.text.squish).to eq("Enter to add")
    end

    it "offers the new-list dialog even before the first list" do
      sign_in(account)
      get member_todo_lists_path
      expect(Nokogiri::HTML(response.body).at_css("dialog[data-test='todo-list-new-dialog'] input[name='name']")).to be_present
    end

    it "una lista senza voci dice che è vuota, non «0 / 0 completate»" do
      sign_in(account)
      create(:todo_list, account:, organization: org, name: "Lista vuota")

      get member_todo_lists_path

      progress = Nokogiri::HTML(response.body).css("[data-test='todo-list-progress']").text.squish
      expect(progress).to eq(I18n.t("member.todo_lists.progress_empty"))
    end
  end

  describe "GET show" do
    it "lista propria → 200 con affordance di modifica (form aggiungi voce)" do
      sign_in(account)
      list = create(:todo_list, account:, organization: org)
      get member_todo_list_path(list)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("todo-item-form")
    end

    it "lista condivisa con me → 200 in sola lettura (nessun form di modifica)" do
      sign_in(account)
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :member)
      list = create(:todo_list, account: owner, organization: org)
      create(:todo_share, list:, account:)

      get member_todo_list_path(list)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("todo-item-form")
    end

    it "lista altrui non condivisa → 404 (anti-BOLA)" do
      sign_in(account)
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :member)
      list = create(:todo_list, account: owner, organization: org)

      get member_todo_list_path(list)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "crea la lista e reindirizza alla show" do
      sign_in(account)
      expect do
        post member_todo_lists_path, params: { name: "Oggi" }
      end.to change(Todos::List, :count).by(1)
      expect(response).to redirect_to(member_todo_list_path(Todos::List.last))
    end

    it "nome vuoto → 422 re-render new" do
      sign_in(account)
      post member_todo_lists_path, params: { name: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET new" do
    it "→ 200 (form nuova lista)" do
      sign_in(account)
      get new_member_todo_list_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH update / DELETE destroy / reorder" do
    it "aggiorna la lista" do
      sign_in(account)
      list = create(:todo_list, account:, organization: org, name: "Vecchio")
      patch member_todo_list_path(list), params: { name: "Nuovo" }
      expect(list.reload.name).to eq("Nuovo")
    end

    it "update con nome vuoto → 422 re-render edit, nome invariato" do
      sign_in(account)
      list = create(:todo_list, account:, organization: org, name: "Vecchio")
      patch member_todo_list_path(list), params: { name: "" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(list.reload.name).to eq("Vecchio")
    end

    it "elimina la lista" do
      sign_in(account)
      list = create(:todo_list, account:, organization: org)
      delete member_todo_list_path(list)
      expect(Todos::List.exists?(list.id)).to be(false)
    end

    it "non posso modificare una lista altrui → 404" do
      sign_in(account)
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :member)
      list = create(:todo_list, account: owner, organization: org)
      patch member_todo_list_path(list), params: { name: "Hack" }
      expect(response).to have_http_status(:not_found)
    end

    it "riordina le mie liste → 200" do
      sign_in(account)
      a = create(:todo_list, account:, organization: org, position: 0)
      b = create(:todo_list, account:, organization: org, position: 0)
      patch reorder_member_todo_lists_path, params: { ordered_ids: [ b.id, a.id ] }
      expect(response).to have_http_status(:ok)
      expect(b.reload.position).to eq(0)
      expect(a.reload.position).to eq(1)
    end
  end

  # Page refactor (2026-10-01): same shape as the other refactored pages.
  describe "page layout" do
    def html
      Capybara.string(response.body)
    end

    let(:colleague) do
      create(:account, name: "Marta Rossi").tap { |a| create(:membership, account: a, organization: org, role: :member) }
    end
    let(:list) { create(:todo_list, account:, organization: org, name: "Release", color: "emerald") }

    before do
      allow_n_plus_one do
        create(:todo_item, list:, title: "Update the changelog", done: false)
        create(:todo_item, list:, title: "Try staging", done: false)
        create(:todo_item, list:, title: "Tag the version", done: true)
        create(:todo_share, list:, account: colleague)
      end
      sign_in(account)
    end

    describe "index" do
      before { get member_todo_lists_path }

      let(:card) { html.find("[data-test='todo-list-card'][data-id='#{list.id}']") }

      it "shows a panel per list with its title link, progress bar, every item and who the list is shared with" do
        expect(card).to have_link("Release", href: member_todo_list_path(list))
        expect(card).to have_css("[data-test='todo-list-bar']")
        expect(card.all("[data-test='todo-panel-item-title']").map(&:text).map(&:strip))
          .to eq([ "Update the changelog", "Try staging", "Tag the version" ])
        expect(card).to have_text(I18n.t("member.todo_lists.shared_with", names: "Marta Rossi"))
      end

      it "lets items be added, ticked and removed right from the panel" do
        expect(card).to have_css("form[action='#{member_todo_list_items_path(list, from: "index")}'] input[name='title']")
        item = list.items.find_by!(title: "Try staging")
        expect(card).to have_css("form[action='#{toggle_member_todo_list_item_path(list, item, from: "index")}']")
        expect(card).to have_css("form[action='#{member_todo_list_item_path(list, item, from: "index")}'] input[name='_method'][value='delete']", visible: :all)
      end

      it "opens the new list in a dialog from the header, with name and colour, and keeps nothing outside the panels" do
        expect(html).to have_css("[data-test='todo-lists-new'][data-action*='ui--dialog#open']")
        dialog = html.find("dialog[data-test='todo-list-new-dialog']", visible: :all)
        expect(dialog).to have_css("form[action='#{member_todo_lists_path(from: "index")}'] input[name='name']", visible: :all)
        expect(dialog).to have_css("input[type='radio'][name='color'][value='emerald']", visible: :all)
        expect(html).to have_no_text("My lists") # no loose label above the panels
        # F24: the standard modal shell, Create in the header and no footer or icon X.
        expect(dialog[:class]).to include("dark:bg-zinc-950", "rounded-xl")
        expect(dialog).to have_css("form header [data-test='todo-list-dialog-submit']", visible: :all)
        expect(dialog).to have_css("[data-test='todo-list-new-dialog-panel']", visible: :all)
        expect(dialog).to have_css("header [data-action='ui--dialog#close']", count: 1, visible: :all)
      end

      it "uses the list colour and lets the lists be dragged" do
        expect(card).to have_css("[data-test='todo-list-color'].bg-emerald-500")
        expect(html).to have_css("[data-controller='todo-reorder'][data-todo-reorder-url-value='#{reorder_member_todo_lists_path}'] [data-todo-reorder-target='item']")
      end
    end

    describe "editing from the index" do
      it "adds, ticks and removes an item and comes back to the index" do
        post member_todo_list_items_path(list, from: "index"), params: { title: "Write the notes" }
        expect(response).to redirect_to(member_todo_lists_path(focus: list.id)) # cursor back in the add field
        item = list.items.find_by!(title: "Write the notes")

        patch toggle_member_todo_list_item_path(list, item, from: "index"), headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
        expect(response).to redirect_to(member_todo_lists_path)
        expect(item.reload).to be_done

        delete member_todo_list_item_path(list, item, from: "index")
        expect(response).to redirect_to(member_todo_lists_path)
        expect(list.items.exists?(item.id)).to be(false)
      end

      it "creates a list and stays on the index" do
        post member_todo_lists_path(from: "index"), params: { name: "Next week" }

        created = Todos::List.find_by!(name: "Next week", account_id: account.id)
        expect(response).to redirect_to(member_todo_lists_path(focus: created.id))
      end

      it "shows a shared list without the editing controls" do
        owner = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
        shared = create(:todo_list, account: owner, organization: org, name: "Theirs")
        allow_n_plus_one { create(:todo_item, list: shared, title: "Their item") }
        create(:todo_share, list: shared, account:)

        get member_todo_lists_path

        panel = html.find("[data-test='todo-list-shared-card'][data-id='#{shared.id}']")
        expect(panel).to have_text("Their item")
        expect(panel).to have_no_css("form")
      end
    end

    it "offers the colours in the list form" do
      get edit_member_todo_list_path(list)

      expect(html).to have_css("input[type='radio'][name='color'][value='emerald'][checked]")
    end

    describe "show" do
      before { get member_todo_list_path(list) }

      it "says how many are done with a bar" do
        expect(html.find("[data-test='todo-list-stats']")).to have_text(I18n.t("member.todo_lists.progress_header", done: 1, total: 3))
      end

      it "puts the add field on top of the items and the ticket behind a link" do
        box = html.find("[data-test='todo-items']")
        expect(box).to have_css("[data-test='todo-item-form'] + #todo_items, [data-test='todo-item-form'] ~ #todo_items")
        expect(box).to have_css("details [data-test='todo-item-ticket-select']", visible: :all)
      end

      it "moves done items to a Completed group" do
        group = html.find("[data-test='todo-items-done']", visible: :all)
        expect(group).to have_text(I18n.t("member.todo_lists.item.completed", count: 1))
        expect(group).to have_css("[data-test='todo-item-title']", text: "Tag the version", visible: :all)
      end

      it "lets an item be renamed" do
        item = list.items.first
        expect(html).to have_css("form[action='#{member_todo_list_item_path(list, item)}'] input[name='title']", visible: :all)
      end

      it "keeps Share as a button and moves Edit and Delete to the menu" do
        expect(html).to have_css("[data-test='todo-list-share']")
        menu = html.find("[data-test='todo-list-more-menu']")
        expect(menu).to have_css("[data-test='todo-list-edit']", visible: :all)
        expect(menu).to have_css("[data-test='todo-list-delete'][data-turbo-confirm]", visible: :all)
      end

      it "says who the list is shared with and shares from a dialog" do
        expect(response.body).to include(I18n.t("member.todo_lists.shared_with_readonly", names: "Marta Rossi"))
        expect(html).to have_css("dialog [data-test='todo-share-form'][action='#{member_todo_list_sharing_path(list)}']", visible: :all)
        # F24: the standard modal shell, Save in the header and no footer or icon X.
        dialog = html.find("dialog[data-test='todo-share-dialog']", visible: :all)
        expect(dialog[:class]).to include("dark:bg-zinc-950", "rounded-xl")
        expect(dialog).to have_css("[data-test='todo-share-form'] header [data-test='todo-share-submit']", visible: :all)
        expect(dialog).to have_css("[data-test='todo-share-dialog-panel']", visible: :all)
        expect(dialog).to have_css("[data-action='ui--dialog#close']", count: 1, visible: :all)
      end
    end
  end
end
