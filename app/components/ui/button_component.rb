# frozen_string_literal: true

module Ui
  # Bottone DS. Reso come:
  #   - <a>            (default, quando è passato `href` senza `method:`)
  #   - <button type>  (nessun `href`) — submit di un form esterno via `form: "<id>"` in options
  #   - button_to      (form-wrapped POST/PUT/PATCH/DELETE, quando `href` + `method:`) → è così che
  #                     le azioni MUTANTI dell'header (watch/delete/approve/github…) usano il
  #                     componente invece di scrivere `button_to` a mano (CSRF + _method gestiti da Rails).
  #   - submit del modulo condiviso (`href` + `method:` + `form_id:`) → azione mutante SENZA un
  #                     `<form>` proprio: punta il modulo unico della pagina
  #                     (`Ui::RowActionsFormComponent`) e sceglie l'indirizzo con `formaction`.
  #                     È la forma da usare nelle AZIONI DI RIGA di un elenco: un `<form>` per
  #                     azione per riga porta un token CSRF diverso ciascuno, quindi il peso della
  #                     pagina cresce con le righe e non si comprime (CYRA-571).
  #
  # `confirm:`     → `data-turbo-confirm` (conferma nativa Turbo) su tutte e tre le forme.
  # `form_class:`  → classe del `<form>` wrapper del button_to (es. "pointer-events-auto").
  # slot `trailing`→ contenuto DOPO la label (es. il badge conteggio watcher accanto a "Watch").
  #
  # `icon_only:`   → bottone quadrato con la sola icona: la `label` non si vede ma resta obbligatoria,
  #                  perché diventa `aria-label` (lettori di schermo) e `title` (tooltip nativo al hover).
  # `grouped:`     → il bottone è dentro un `Ui::ButtonGroupComponent`: rinuncia al proprio raggio,
  #                  che lo dà il wrapper del gruppo con `overflow-hidden`. Lo inietta il gruppo, non
  #                  il caller (vedi il lambda di slot in ButtonGroupComponent).
  #
  # Varianti e size sono simboli validati contro mappe frozen (niente conditional in ERB).
  # Le azioni nell'header di pagina usano SEMPRE size :sm (vedi DESIGN.md / COMPONENTS.md,
  # regola closeyourit-page-actions-in-header).
  class ButtonComponent < BaseComponent
    renders_one :trailing

    # Raggio e focus ring sono FUORI da BASE perché dentro un gruppo cambiano entrambi.
    # Il raggio va TOLTO (lo dà il wrapper): due utility di border-radius in conflitto non si
    # risolvono per ordine nell'attributo class (vince l'ordine nel CSS generato), quindi non
    # basterebbe appendere `rounded-none`.
    BASE = "inline-flex items-center justify-center gap-[7px] whitespace-nowrap " \
           "focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed"

    RADIUS = "rounded-md"

    # Ring esterno con offset: si vede tutto perché il bottone sta per conto suo.
    FOCUS = "focus-visible:ring-2 focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400 focus-visible:ring-offset-1"
    # Ring INTERNO nel gruppo: il wrapper ha `overflow-hidden` per clippare i raggi dei figli, e
    # clipperebbe anche il ring esterno — un focus da tastiera invisibile. `ring-inset` lo disegna
    # dentro il bottone, quindi sopravvive al clipping (niente offset: sarebbe clippato anch'esso).
    FOCUS_GROUPED = "focus-visible:ring-2 focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400 focus-visible:ring-inset"

    VARIANTS = {
      primary: "bg-indigo-600 text-white hover:bg-indigo-700 font-semibold",
      secondary: "text-zinc-900 dark:text-zinc-100 bg-white dark:bg-zinc-900 border border-stone-200 dark:border-zinc-800 hover:bg-stone-50 dark:hover:bg-zinc-800 font-medium",
      secondary_muted: "text-gray-500 dark:text-zinc-400 bg-white dark:bg-zinc-900 border border-stone-200 dark:border-zinc-800 hover:bg-stone-50 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100 font-medium",
      ghost: "text-gray-500 dark:text-zinc-400 hover:bg-stone-100 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100 font-medium",
      tinted: "text-indigo-600 dark:text-indigo-400 bg-indigo-50 dark:bg-indigo-500/15 hover:bg-indigo-100 dark:hover:bg-indigo-500/25 font-medium",
      tinted_outline: "text-indigo-600 dark:text-indigo-400 bg-indigo-50 dark:bg-indigo-500/15 border border-indigo-200 dark:border-indigo-500/40 hover:bg-indigo-100 dark:hover:bg-indigo-500/25 font-medium",
      danger: "bg-red-600 text-white hover:bg-red-700 font-semibold",
      danger_outline: "text-red-600 dark:text-red-400 bg-white dark:bg-zinc-900 border border-stone-200 dark:border-zinc-800 hover:bg-red-50 dark:hover:bg-red-500/15 font-medium",
      success: "bg-emerald-600 text-white hover:bg-emerald-700 font-semibold",
      success_outline: "text-emerald-700 dark:text-emerald-300 bg-white dark:bg-zinc-900 border border-stone-200 dark:border-zinc-800 hover:bg-emerald-50 dark:hover:bg-emerald-500/15 font-medium"
    }.freeze

    SIZES = {
      sm: "h-7 px-3 text-[12px]",
      md: "h-[34px] px-3.5 text-[12.5px]",
      lg: "h-10 px-4 text-[13px]"
    }.freeze

    # Gemelle quadrate delle SIZES per `icon_only:` — stessa altezza, larghezza pari all'altezza
    # invece del padding orizzontale, così il bottone resta allineato agli altri della stessa riga.
    ICON_ONLY_SIZES = {
      sm: "h-7 w-7 text-[12px]",
      md: "h-[34px] w-[34px] text-[12.5px]",
      lg: "h-10 w-10 text-[13px]"
    }.freeze

    ICON_SIZES = { sm: "text-[11px]", md: "text-[12px]", lg: "text-[13px]" }.freeze

    def initialize(label: nil, variant: :primary, size: :md, type: "button",
                   href: nil, method: nil, confirm: nil, form_class: nil, form_id: nil,
                   icon: nil, icon_only: false, grouped: false,
                   disabled: false, test_id: nil, **options)
      @label = label
      @variant = variant.to_sym
      @size = size.to_sym
      @type = type
      @href = href
      @method = method
      @confirm = confirm
      @form_class = form_class
      @form_id = form_id
      @icon = icon
      @icon_only = icon_only
      @grouped = grouped
      @disabled = disabled
      @test_id = test_id
      @options = options

      raise ArgumentError, "variante sconosciuta: #{@variant}" unless VARIANTS.key?(@variant)
      raise ArgumentError, "size sconosciuta: #{@size}" unless SIZES.key?(@size)
      # `icon:` is a bare Lucide name (CYRA-926): a leftover Font Awesome name fails here, loudly.
      raise ArgumentError, "icon: takes a Lucide name, not a Font Awesome class (got: #{@icon})" if @icon.to_s.start_with?("fa-")
      raise ArgumentError, "icon_only richiede icon:" if @icon_only && @icon.blank?
      raise ArgumentError, "icon_only richiede label: (diventa aria-label)" if @icon_only && @label.blank?
      raise ArgumentError, "form_id richiede href: (l'indirizzo dell'azione)" if @form_id && @href.blank?
      raise ArgumentError, "form_id richiede method: (il verbo dell'azione)" if @form_id && @method.blank?
    end

    private

    def klass
      [ BASE, (@grouped ? FOCUS_GROUPED : FOCUS), (RADIUS unless @grouped),
        VARIANTS.fetch(@variant), size_klass ].compact.join(" ")
    end

    def size_klass
      (@icon_only ? ICON_ONLY_SIZES : SIZES).fetch(@size)
    end

    # Contenuto interno, identico nelle tre forme polimorfiche (button_to / <a> / <button>).
    # Con `icon_only` resta la sola icona: label e slot `trailing` non vengono resi (la label
    # sopravvive come aria-label/title, vedi html_options).
    def body
      return icon_tag if @icon_only

      safe_join([ icon_tag, @label || content, (trailing if trailing?) ].compact)
    end

    def icon_tag
      return nil if @icon.blank?

      render(Ui::IconComponent.new(name: @icon, class: "w-[1.25em] #{icon_klass}"))
    end

    def icon_klass
      ICON_SIZES.fetch(@size)
    end

    def shared_form_submit?
      @form_id.present?
    end

    def button_to?
      @method.present? && @href.present?
    end

    def html_options
      opts = merge_options(base_class: klass, test_id: @test_id, options: @options)
      opts[:disabled] = true if @disabled
      opts[:data] = (opts[:data] || {}).merge(turbo_confirm: @confirm) if @confirm
      if @icon_only
        # La label del caller è il default, non un override: un `aria:`/`title:` esplicito vince.
        opts[:aria] = { label: @label }.merge(opts[:aria] || {})
        opts[:title] ||= @label
      end
      opts
    end

    def button_to_options
      opts = html_options.merge(method: @method)
      opts[:form] = { class: @form_class } if @form_class
      opts
    end

    # Submit del modulo condiviso: `form` lo aggancia, `formaction` sceglie l'indirizzo. Il verbo
    # diverso da POST viaggia come `_method` nel nome/valore del submitter, che il browser include
    # nell'invio esattamente come farebbe il campo nascosto di un button_to.
    def shared_form_options
      opts = html_options.merge(type: "submit", form: @form_id, formaction: @href)
      opts.merge!(name: "_method", value: @method.to_s) unless @method.to_s.casecmp?("post")
      opts
    end
  end
end
