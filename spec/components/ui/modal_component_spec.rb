# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ModalComponent, type: :component do
  def dialog = page.find("dialog", visible: :all)

  it "draws the standard shell: dark ground, header panel, content in its own panel (F24)" do
    render_inline(described_class.new(title: "Resolve error", subtitle: "ERR-12", test_id: "resolve")) do |modal|
      modal.with_actions { "<button>Close</button>".html_safe }
      "Body text"
    end

    expect(dialog[:class]).to include("bg-stone-100", "dark:bg-zinc-950", "rounded-xl", "backdrop:backdrop-blur-sm")
    expect(dialog["data-test"]).to eq("resolve")
    header = dialog.find("header", visible: :all)
    expect(header).to have_text(:all, "Resolve error")
    expect(header).to have_text(:all, "ERR-12")
    expect(header).to have_css("button", text: "Close", visible: :all)
    expect(dialog).to have_css("[data-test='resolve-panel']", text: "Body text", visible: :all)
  end

  # A page has one page header: a dialog header must not reuse its page-header-* hooks, or a
  # dialog that opens by itself (the changelog) makes every page-header lookup ambiguous.
  # A page has one h1: a dialog title is an h2, even in a dialog rendered closed on every page.
  it "titles the dialog with an h2, never a second h1" do
    render_inline(described_class.new(title: "Resolve error"))
    expect(dialog).to have_css("h2", text: "Resolve error", visible: :all)
    expect(dialog).to have_no_css("h1", visible: :all)
  end

  it "names its header parts after the dialog, never as the page header" do
    render_inline(described_class.new(title: "Resolve error", test_id: "resolve"))
    expect(dialog).to have_css("[data-test='resolve-header-title-row']", visible: :all)

    render_inline(described_class.new(title: "Untitled hooks"))
    expect(dialog).to have_css("[data-test='modal-header-title-row']", visible: :all)
    expect(dialog).to have_no_css("[data-test^='page-header-']", visible: :all)
  end

  it "keeps the caller's wiring on the dialog" do
    render_inline(described_class.new(title: "T", id: "d1",
                                      data: { "ui--dialog-target": "dialog", action: "click->ui--dialog#backdrop" })) { "x" }

    expect(dialog[:id]).to eq("d1")
    expect(dialog["data-ui--dialog-target"]).to eq("dialog")
    expect(dialog["data-action"]).to eq("click->ui--dialog#backdrop")
  end

  it "sizes the shell from a fixed map and rejects unknown sizes" do
    render_inline(described_class.new(title: "T", size: :sm)) { "x" }
    expect(dialog[:class]).to include("w-[min(28rem,calc(100vw-2rem))]")

    expect { described_class.new(title: "T", size: :huge) }.to raise_error(ArgumentError)
  end

  it "pads the content panel unless told the rows draw their own padding" do
    render_inline(described_class.new(title: "T", test_id: "m")) { "x" }
    expect(page.find("[data-test='m-panel']", visible: :all)[:class]).to include("p-4")

    render_inline(described_class.new(title: "T", padded: false, test_id: "m")) { "x" }
    expect(page.find("[data-test='m-panel']", visible: :all)[:class]).not_to include("p-4")
  end

  it "wraps header and panel in one form when given form options, so header buttons submit it" do
    render_inline(described_class.new(title: "T", form: { url: "/things", method: :post, data: { test: "f" } })) do |modal|
      modal.with_actions { "<button type='submit'>Save</button>".html_safe }
      "<input name='x'>".html_safe
    end

    form = dialog.find("form[data-test='f']", visible: :all)
    expect(form["action"]).to eq("/things")
    expect(form).to have_css("header button[type='submit']", visible: :all)
    expect(form).to have_css("input[name='x']", visible: :all)
  end

  it "draws no empty panel when there is no content" do
    render_inline(described_class.new(title: "Delete it?", test_id: "m"))

    expect(page).not_to have_css("[data-test='m-panel']", visible: :all)
  end
end
