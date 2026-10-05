# frozen_string_literal: true

module Ui
  # The confirmation of a gesture that cannot be undone (F3, F16, C77): a native <dialog> that names
  # the thing and says what disappears with it. The caller's content holds the trigger, which may sit
  # inside a ⋯ menu: the dialog lives outside it, so a closed <details> never hides it.
  class ConfirmDialogComponent < BaseComponent
    OPEN = "ui--dialog#open"

    renders_one :body

    # params: extra fields the gesture sends, e.g. the impact digest a shared secret is checked against.
    # dialog_id: lets a RemoteTriggerComponent outside this block open it (several dialogs for one ⋯ menu).
    def initialize(title:, url:, confirm_label:, method: :delete, params: {}, dialog_id: nil, test_id: nil, **options)
      @title = title
      @dialog_id = dialog_id
      @params = params
      @url = url
      @confirm_label = confirm_label
      @method = method
      @test_id = test_id
      @options = options
    end

    # The ⋯ menu item that opens the dialog: drawn here so no view writes a <button> by hand (F1).
    def menu_trigger(label:, icon:, test_id: nil)
      helpers.tag.button(type: "button", class: RowMenuComponent.item_class(:danger), data: { action: OPEN, test: test_id }) do
        helpers.safe_join([ helpers.render(Ui::IconComponent.new(name: icon, class: "w-[1.25em] text-[12px]")), label ])
      end
    end

    # The same gesture as a visible row button (Revoke, Restore…): it keeps its place and opens the dialog.
    def button_trigger(label:, icon: nil, variant: :danger_outline, test_id: nil)
      helpers.render(Ui::ButtonComponent.new(label: label, icon: icon, variant: variant, size: :sm, test_id: test_id,
                                             data: { action: OPEN }))
    end

    # A ⋯ menu item that opens a dialog rendered elsewhere, by id: the dialog stays outside the menu (C77)
    # even when the menu holds one gesture per version.
    class RemoteTriggerComponent < BaseComponent
      def initialize(dialog_id:, label:, test_id: nil)
        @dialog_id = dialog_id
        @label = label
        @test_id = test_id
      end

      def call
        tag.span(class: "contents", data: { controller: "ui--dialog" }) do
          tag.button(@label, type: "button", class: "font-semibold text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-200 dark:hover:text-indigo-300",
                             data: { action: OPEN, "ui--dialog-dialog-param": @dialog_id, test: @test_id })
        end
      end
    end

    private

    def html_options
      opts = merge_options(base_class: "contents", options: @options)
      opts[:data] = (opts[:data] || {}).merge(controller: "ui--dialog")
      opts
    end

    def confirm_test_id = @test_id && "#{@test_id}-confirm"

    # CYRA-728: the dialog is the confirmation gesture, so the red button always carries confirm=1.
    def confirm_params = @params.merge(confirm: 1)
  end
end
