# frozen_string_literal: true

module Ui
  # Gruppo di bottoni attaccati (segmented control / coppia di decisione). Il wrapper porta il raggio
  # e `overflow-hidden`, così i figli — che rinunciano al proprio raggio — restano squadrati dentro e
  # arrotondati solo agli estremi del gruppo.
  #
  #   <%= render Ui::ButtonGroupComponent.new(test_id: "vault-decision") do |group| %>
  #     <% group.with_button(variant: :success, size: :sm, icon: "check", icon_only: true,
  #          label: t("…approve"), href: approve_path, method: :post, form_class: "contents") %>
  #     <% group.with_button(variant: :danger, size: :sm, icon: "x", icon_only: true,
  #          label: t("…reject"), data: { action: "ui--dialog#open" }) %>
  #   <% end %>
  #
  # Il `grouped: true` lo inietta lo slot, non il caller: chi usa il gruppo non deve sapere come si
  # spegne il raggio del figlio.
  #
  # GOTCHA `button_to`: un figlio con `href` + `method` viene avvolto da Rails in un `<form>`, che
  # diventerebbe lui l'item della flex e romperebbe l'allineamento. Passa `form_class: "contents"`
  # (display:contents) così il `<button>` resta figlio diretto del wrapper.
  #
  # Nessun bordo né divisore di default: il gruppo non sa se i figli sono pieni (attaccati, come
  # approva/rifiuta) o trasparenti (cornice + separatori, come i toggle di vista). Chi vuole la
  # cornice la passa — `class: "border border-stone-200 bg-white divide-x divide-stone-200"`.
  class ButtonGroupComponent < BaseComponent
    renders_many :buttons, ->(**options) { Ui::ButtonComponent.new(**options, grouped: true) }

    WRAPPER = "inline-flex items-center rounded-md overflow-hidden"

    def initialize(test_id: nil, **options)
      @test_id = test_id
      @options = options
    end

    private

    def html_options
      merge_options(base_class: WRAPPER, test_id: @test_id, options: @options)
    end
  end
end
