# frozen_string_literal: true

require "rails_helper"

# Clicking an item's text opened the rename field without the caret in it: a second click was needed
# before typing. CYRA-1107
RSpec.describe "Renaming a todo item in place", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let(:account) do
    create(:account).tap { |acc| create(:membership, account: acc, organization: org, role: :member) }
  end
  let(:list) { create(:todo_list, account:, organization: org) }
  let!(:item) { create(:todo_item, list:, title: "Write the tests") }

  it "puts the caret in the field, ready to type" do
    sign_in_as(account)
    visit member_todo_list_path(list)

    find("[data-test='todo-item-title']", text: "Write the tests").click

    expect(page).to have_css("[data-test='todo-item-rename'][open] input[name='title']:focus")
    expect(page.evaluate_script("document.activeElement.value")).to eq("Write the tests")
  end
end
