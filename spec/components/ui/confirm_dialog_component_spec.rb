# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ConfirmDialogComponent, type: :component do
  def render_dialog(**options, &block)
    render_inline(described_class.new(title: "Delete the Staging environment?", url: "/member/environments/7",
                                      confirm_label: "Delete", test_id: "environment-delete-dialog-7", **options), &block)
  end

  it "wraps the trigger and the dialog in one dialog controller" do
    render_dialog { "<button data-action='#{described_class::OPEN}'>Delete</button>".html_safe }

    expect(page).to have_css("div[data-controller='ui--dialog'] button[data-action='ui--dialog#open']", text: "Delete")
    expect(page).to have_css("div[data-controller='ui--dialog'] dialog[data-ui--dialog-target='dialog']", visible: :all)
  end

  it "names the thing in the title and says what disappears in the body (F16)" do
    render_dialog do |dialog|
      dialog.with_body { "Nothing uses it: only the environment disappears." }
    end

    expect(page).to have_css("dialog header h2", text: "Delete the Staging environment?", visible: :all)
    expect(page).to have_css("dialog", text: "Nothing uses it: only the environment disappears.", visible: :all)
  end

  it "sends the gesture with a red button and the given method" do
    render_dialog

    form = page.find("dialog form[action='/member/environments/7']", visible: :all)
    expect(form).to have_css("input[name='_method'][value='delete']", visible: :all)
    expect(form).to have_css("button.bg-red-600[data-test='environment-delete-dialog-7-confirm']", text: "Delete", visible: :all)
  end

  it "closes without doing anything from Cancel" do
    render_dialog

    expect(page).to have_css("dialog button[type='button'][data-action='ui--dialog#close']", text: I18n.t("ui.confirm_dialog.cancel"), visible: :all)
  end

  it "draws the ⋯ menu item that opens it, so no view writes a button by hand (F1)" do
    render_dialog do |dialog|
      dialog.menu_trigger(label: "Delete", icon: "trash", test_id: "environment-delete-7")
    end

    trigger = page.find("button[data-test='environment-delete-7']")
    expect(trigger[:type]).to eq("button")
    expect(trigger["data-action"]).to eq("ui--dialog#open")
    expect(trigger[:class]).to eq(Ui::RowMenuComponent.item_class(:danger))
    expect(trigger).to have_css("svg[data-icon='trash']")
    expect(trigger).to have_text("Delete")
  end

  it "never uses the browser confirm box" do
    render_dialog

    expect(rendered_content).not_to include("turbo-confirm")
  end

  # CYRA-728 — the dialog is the confirmation gesture: the red button tells the server so (confirm=1).
  it "sends the confirmation with the red button" do
    render_dialog

    expect(page).to have_css("dialog form input[type='hidden'][name='confirm'][value='1']", visible: :all)
  end

  # CYRA-924 — a gesture that is a visible button on the row keeps its place and opens the dialog (F16, P2).
  it "draws a visible row button that opens the dialog" do
    render_dialog { |dialog| dialog.button_trigger(label: "Revoke", icon: "ban", test_id: "token-revoke-7") }

    trigger = page.find("button[data-test='token-revoke-7']")
    expect(trigger[:type]).to eq("button")
    expect(trigger["data-action"]).to eq("ui--dialog#open")
    expect(trigger[:class]).to include("text-red-600")
    expect(trigger).to have_text("Revoke")
  end

  # CYRA-924 — a gesture the server checks against an impact digest sends it with the confirmation.
  it "sends extra params with the red button" do
    render_dialog(params: { confirmation_digest: "abc" })

    expect(page).to have_css("dialog form input[name='confirmation_digest'][value='abc']", visible: :all)
    expect(page).to have_css("dialog form input[name='confirm'][value='1']", visible: :all)
  end

  # CYRA-924 — several dialogs for one ⋯ menu (one per version): each dialog has an id and lives
  # outside the menu, the menu item opens it from afar (F16, C77).
  it "gives the dialog an id a remote trigger can open" do
    render_dialog(dialog_id: "rollback-v2")

    expect(page).to have_css("dialog#rollback-v2", visible: :all)
  end

  it "draws a remote trigger that opens a dialog by id" do
    render_inline(described_class::RemoteTriggerComponent.new(dialog_id: "rollback-v2", label: "Restore", test_id: "rollback-v2-open"))

    trigger = page.find("button[data-test='rollback-v2-open']")
    expect(trigger[:type]).to eq("button")
    expect(trigger["data-action"]).to eq("ui--dialog#open")
    expect(trigger["data-ui--dialog-dialog-param"]).to eq("rollback-v2")
    expect(page).to have_css("[data-controller='ui--dialog'] button[data-test='rollback-v2-open']")
  end
end
