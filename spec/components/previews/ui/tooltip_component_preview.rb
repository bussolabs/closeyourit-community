# frozen_string_literal: true

module Ui
  class TooltipComponentPreview < ViewComponent::Preview
    def default = render(Ui::TooltipComponent.new(text: "S.M.A.R.T. segnala lo stato di salute dei dischi del server."))

    def with_title = render(Ui::TooltipComponent.new(title: "Fingerprint", text: "Impronta che raggruppa gli errori simili in un'unica issue."))

    def muted = render(Ui::TooltipComponent.new(text: "Variante discreta: solo l'icona grigia, senza pallino pieno.", tone: :muted))

    def tip = render(Ui::TooltipComponent.new(text: "Trascina le card tra le colonne per cambiarne lo stato.", tone: :tip))

    def tip_with_title = render(Ui::TooltipComponent.new(title: "Suggerimento", text: "Usa i filtri salvati per tornare rapidamente a una vista ricorrente.", tone: :tip))

    def bottom_placement = render(Ui::TooltipComponent.new(text: "Questo popup si apre sotto il pallino.", placement: :bottom))

    def long_text = render(Ui::TooltipComponent.new(title: "SLA", text: "La percentuale di uptime misura la quota di controlli andati a buon fine nella finestra selezionata (24h, 7 giorni, 30 giorni, 1 anno)."))

    def custom_icon = render(Ui::TooltipComponent.new(icon: "circle-question-mark", text: "Icona personalizzabile via il parametro icon."))
  end
end
