# frozen_string_literal: true

module Ui
  # Switch (toggle) auto-save del design system. Renderizza una riga (icona opzionale +
  # label + hint a sinistra, esito + pill a destra) cablata al controller Stimulus `ui--switch`:
  # il toggle è ottimistico e persiste via fetch PATCH su `url` con `{ name => "1"/"0" }`,
  # senza ricaricare la pagina. Il testo visibile arriva già tradotto dalla view (`t(...)`).
  #
  # CYRA-563 — il controller sta sulla RIGA, non sulla pill: l'etichetta che dichiara «si applica
  # subito» (e che dopo il PATCH diventa «salvato» o «non salvato») è fratello del bottone, e
  # Stimulus cerca i target solo dentro l'elemento del controller. Senza quella dichiarazione un
  # interruttore che si salva da sé e un campo che aspetta il Salva sono indistinguibili a occhio.
  # Le parole dell'esito arrivano da qui tradotte, come in SelectComponent (CYRA-442): dentro il
  # JS nessuna scelta di lingua le raggiungerebbe.
  class SwitchComponent < BaseComponent
    # `immediate_note: false` drops the resting «applies instantly» note, for a block that says it once
    # above its switches; the slot stays for the saved / not saved outcome. CYRA-883
    def initialize(name:, url:, label:, checked: false, hint: nil, icon: nil, test_id: nil,
                   immediate_note: true, **options)
      @name = name.to_s
      @immediate_note = immediate_note
      @url = url
      @label = label
      @checked = checked ? true : false
      @hint = hint
      @icon = icon
      @test_id = test_id
      @options = options
    end

    private

    PILL_BASE = "relative inline-flex h-5 w-9 items-center rounded-full shrink-0 cursor-pointer " \
                "focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400 " \
                "disabled:opacity-50 disabled:cursor-not-allowed"

    # `text-gray-400`: nota di servizio, non un dato — resta sotto la label e l'hint nella gerarchia.
    # Il controller la ricolora (emerald/rosso) solo quando c'è un esito da riferire.
    STATUS_CLASS = "shrink-0 text-right text-[10.5px] text-gray-400 dark:text-zinc-500"

    def pill_class
      "#{PILL_BASE} #{@checked ? 'bg-indigo-600' : 'bg-stone-300 dark:bg-zinc-600'}"
    end

    def knob_class
      base = "inline-block h-4 w-4 transform rounded-full bg-white dark:bg-zinc-900 motion-safe:transition"
      "#{base} #{@checked ? 'translate-x-[18px]' : 'translate-x-[2px]'}"
    end

    def status_class
      STATUS_CLASS
    end

    def immediate_label
      @immediate_note ? t("ui.switch.immediate") : ""
    end

    def row_options
      {
        class: "flex items-center gap-3 px-5 py-3.5",
        data: {
          controller: "ui--switch",
          "ui--switch-url-value": @url,
          "ui--switch-param-value": @name,
          "ui--switch-checked-value": @checked,
          "ui--switch-immediate-label-value": immediate_label,
          "ui--switch-saved-label-value": t("ui.switch.saved"),
          "ui--switch-failed-label-value": t("ui.switch.failed")
        }
      }
    end

    def button_options
      opts = merge_options(base_class: pill_class, options: @options)
      opts[:data] = (opts[:data] || {}).merge(
        action: "ui--switch#toggle", "ui--switch-target": "pill", test: @test_id
      ).compact
      opts.merge(type: "button", role: "switch", "aria-checked": @checked.to_s,
                 "aria-labelledby": "#{@name}_switch_label")
    end
  end
end
