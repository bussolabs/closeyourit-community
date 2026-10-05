# frozen_string_literal: true

require "rails_helper"

# The list page parts that need a browser: the share dialog and a ticked item changing group in place.
# Gated by spec/support/js_system.rb (JS_SYSTEM_SPECS=1).
RSpec.describe "Member todo list page in the browser", :js, type: :system do
  let(:org) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end
  let(:list) { create(:todo_list, account:, organization: org, name: "Release") }
  let!(:item) { create(:todo_item, list:, title: "Try staging") }

  it "opens the share dialog from the Share button" do
    sign_in_as(account)
    visit member_todo_list_path(list)

    find("[data-test='todo-list-share']").click

    expect(page).to have_css("[data-test='todo-share-dialog'][open]")
    expect(page).to have_current_path(member_todo_list_path(list))
  end

  it "moves a ticked item to the Completed group without a reload" do
    sign_in_as(account)
    visit member_todo_list_path(list)

    find("[data-test='todo-item-toggle-#{item.id}']").click

    expect(page).to have_css("[data-test='todo-items-done']", text: I18n.t("member.todo_lists.item.completed", count: 1))
    expect(item.reload.done?).to be(true)
  end

  context "with a completed item" do
    let!(:done_item) { create(:todo_item, list:, title: "Write notes", done: true) }
    let!(:other_item) { create(:todo_item, list:, title: "Tell the team") }

    it "keeps the Completed group open when another item is ticked" do
      sign_in_as(account)
      visit member_todo_list_path(list)

      find("[data-test='todo-items-done'] summary").click
      find("[data-test='todo-item-toggle-#{item.id}']").click

      expect(page).to have_css("[data-test='todo-items-done']", text: I18n.t("member.todo_lists.item.completed", count: 2))
      expect(page).to have_css("[data-test='todo-items-done'][open]")
    end

    it "does not drop an open item among the completed ones" do
      sign_in_as(account)
      visit member_todo_list_path(list)
      find("[data-test='todo-items-done'] summary").click

      page.execute_script(<<~JS, item.id, done_item.id)
        const [from, to] = [document.getElementById("todos_item_" + arguments[0]), document.getElementById("todos_item_" + arguments[1])];
        const data = new DataTransfer();
        from.dispatchEvent(new DragEvent("dragstart", { dataTransfer: data, bubbles: true }));
        to.dispatchEvent(new DragEvent("drop", { dataTransfer: data, bubbles: true, cancelable: true }));
      JS

      expect(page).to have_no_css("[data-test='todo-items-done'] #todos_item_#{item.id}")
    end
  end
end
