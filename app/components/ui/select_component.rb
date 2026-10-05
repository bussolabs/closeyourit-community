# frozen_string_literal: true

module Ui
  # Select searchable (regola forms-select). Progressive enhancement: rende un `<select>`
  # nativo che MANTIENE il name → submette e si testa senza JS (rack_test). Con JS lo Stimulus
  # `ui--select` lo arricchisce con search + dropdown custom. `multiple: true` → name `x[]`.
  #
  # options: array di `[label, value]` (3° elemento opzionale = colore famiglia per il pallino).
  class SelectComponent < BaseComponent
    FIELD = "w-full px-3 pr-8 rounded-md border text-zinc-900 dark:text-zinc-100 bg-white dark:bg-zinc-900 " \
            "focus:outline-none focus-visible:ring-2"

    # size: :md (default, invariato — i call site esistenti restano h-[34px]) · :sm per celle
    # dense di tabella (es. cadenza notifiche per-riga) dove 34px eccede l'altezza riga. Additivo.
    SIZES = {
      md: "h-[34px] text-[13px]",
      sm: "h-[30px] text-[12px]"
    }.freeze

    def initialize(name:, options:, label: nil, selected: nil, multiple: false, required: false,
                   placeholder: nil, summary: false, include_blank: false, error: nil, hint: nil,
                   wrapper_class: nil, test_id: nil, aria_label: nil, size: :md, descriptions: nil,
                   disabled_values: nil, remote: nil, prefix: nil)
      @name = name
      # prefix (CYRA-883): { text:, icon: } shown inside the trigger before the value, e.g. "Sort: Most
      # errors" in one control. Only the enhanced trigger shows it; the native fallback stays plain.
      @prefix = prefix&.symbolize_keys
      @options = options
      @label = label
      # remote (CYRA-364): opt-in per i campi il cui vocabolario è troppo grande da caricare intero
      # (es. «Ticket collegato»: 200 voci di tutta l'organizzazione). `options` resta il primo
      # blocco reso dal server — senza JS il campo funziona con quelle — e `ui--remote-options` lo
      # rifornisce dal server mentre si digita. Chiavi: url (obbligatoria), scope_field/scope_param
      # (il campo che porta il contesto), all_label (casella per allargare a tutti i progetti).
      @remote = remote&.symbolize_keys
      # descriptions: hash opt-in { value => testo } → riga di spiegazione per-opzione (CYRA-343). Il
      # dropdown arricchito (ui--select) la rende sotto la voce; il <select> nativo la porta come
      # `title` (tooltip). Assente → comportamento identico a prima (nessun impatto sugli altri select).
      @descriptions = (descriptions || {}).transform_keys(&:to_s)
      # CYRA-350 — opzioni che NON hanno risultati: restano visibili (dicono che quel valore esiste
      # nel vocabolario) ma non si possono scegliere, perché sceglierle porta a una pagina vuota.
      @disabled_values = Array(disabled_values).map(&:to_s).to_set
      @selected = Array(selected).map(&:to_s)
      @multiple = multiple
      @required = required
      @placeholder = placeholder
      # summary: nei filtri il trigger mostra "<placeholder>: a, b +N" (placeholder = noun del filtro).
      @summary = summary
      @include_blank = include_blank
      @error = error
      @hint = hint
      @wrapper_class = wrapper_class
      @test_id = test_id
      # aria_label: nome accessibile per i select SENZA <label> visibile (es. celle di una lista
      # dove il contesto/colonna è già testo adiacente) — MAI in alternativa a un label reale.
      @aria_label = aria_label
      @size = size.to_sym

      raise ArgumentError, "size sconosciuta: #{@size}" unless SIZES.key?(@size)
    end

    private

    def field_klass
      border = if @error
        "border-red-400 focus:border-red-500 focus-visible:ring-red-500"
      else
        "border-stone-200 dark:border-zinc-800 focus:border-indigo-600 dark:focus:border-indigo-400 focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400"
      end
      [ FIELD, SIZES.fetch(@size), border ].join(" ")
    end

    def field_name = @multiple ? "#{@name}[]" : @name

    def dom_id = @name.to_s.delete("[]")

    def selected?(value) = @selected.include?(value.to_s)

    def option_description(value) = @descriptions[value.to_s].presence

    def option_disabled?(value) = @disabled_values.include?(value.to_s)

    def remote? = @remote.present?

    def remote_all_label = @remote&.dig(:all_label).presence

    # Attributi del <select> nativo. aria-label SOLO se non c'è già un <label> visibile (evita
    # un nome accessibile ridondante/doppio annuncio quando il componente renderizza già il label).
    def select_html_options
      opts = { name: field_name, id: dom_id, multiple: @multiple, required: @required,
               class: field_klass, data: { test: @test_id, "ui--select-target": "select" } }
      opts[:data]["ui--remote-options-target"] = "select" if remote?
      opts[:aria] = { label: @aria_label } if @aria_label.present? && @label.blank?
      opts
    end

    # Attributi del wrapper: `ui--select` da solo, oppure affiancato da `ui--remote-options` (che
    # gli rifornisce le opzioni dal server). Due controller sullo stesso elemento, ruoli distinti.
    def wrapper_data
      data = { controller: "ui--select", "ui--select-multiple-value": @multiple,
               "ui--select-summary-value": @summary, "ui--select-placeholder-value": @placeholder,
               "ui--select-selected-label-value": t("ui.select.selected_count", count: "%{count}"),
               "ui--select-search-label-value": t("ui.select.search") }
      if @prefix
        data["ui--select-prefix-value"] = @prefix[:text]
        data["ui--select-prefix-icon-value"] = @prefix[:icon]
      end
      return data unless remote?

      data[:controller] = "ui--select ui--remote-options"
      data["ui--remote-options-url-value"] = @remote[:url]
      data["ui--remote-options-scope-field-value"] = @remote[:scope_field]
      data["ui--remote-options-scope-param-value"] = @remote[:scope_param] if @remote[:scope_param].present?
      data
    end
  end
end
