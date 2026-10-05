# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableComponent::StateComponent, type: :component do
  it "says the table is empty, with an icon and the body (C51)" do
    render_inline(described_class.new(kind: :empty, title: "No secrets yet", body: "Add the first one.", test_id: "state"))
    expect(page).to have_css("[data-test='state'][data-table-state='empty']")
    expect(page).to have_css("h3", text: "No secrets yet")
    expect(page).to have_css("p", text: "Add the first one.")
    expect(page).to have_css("svg[data-icon='inbox']")
  end

  it "offers the reset link when no row matches" do
    render_inline(described_class.new(kind: :no_results, title: "Nothing matches", reset_href: "/x", reset_label: "Reset filters"))
    expect(page).to have_css("[data-table-state='no_results'] svg[data-icon='search']")
    expect(page).to have_link("Reset filters", href: "/x")
  end

  it "announces loading politely" do
    render_inline(described_class.new(kind: :loading, title: "Loading"))
    expect(page).to have_css("[data-table-state='loading'][role='status'][aria-live='polite']", text: "Loading")
  end

  it "announces an error as an alert with a retry link" do
    render_inline(described_class.new(kind: :error, title: "Could not load", reset_href: "/x", reset_label: "Retry"))
    expect(page).to have_css("[data-table-state='error'][role='alert'] svg[data-icon='triangle-alert']")
    expect(page).to have_link("Retry", href: "/x")
  end

  it "renders a custom action" do
    render_inline(described_class.new(kind: :empty, title: "Empty")) do |state|
      state.with_action { "<a href='/new'>Add</a>".html_safe }
    end
    expect(page).to have_link("Add", href: "/new")
  end

  it "rejects an unknown kind" do
    expect { described_class.new(kind: :weird, title: "x") }.to raise_error(ArgumentError, /kind/)
  end
end
