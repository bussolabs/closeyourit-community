# frozen_string_literal: true

module Ui
  # The audit strip: Created and Updated (date + author) on one line that wraps when narrow, with
  # an optional `action` slot at the far end (the "View activity history" button). It draws no
  # surface of its own: the caller's panel does.
  #
  # Presentazionale: il caller calcola data/autore dalla propria fonte (Ticketing::Event o
  # l'activity-log generalizzato). `created_by`/`updated_by` sono NOMI (stringa) o nil — nil =
  # entità di sistema senza autore umano → mostra solo la data. `updated_at` nil → niente blocco Updated.
  #
  # CYRA-406 — `*_by_machine`: un'automazione non si mostra con le iniziali dentro un cerchio, che
  # è il segno delle persone. Stesso posto, stesso peso, icona diversa: chi legge deve poter dire
  # a colpo d'occhio se dietro una modifica c'era una persona o un programma.
  class AuditMetaComponent < BaseComponent
    renders_one :action

    DATE_FORMAT = "%d/%m/%Y · %H:%M"
    # Every piece sits in the same 20px box with no line-height of its own, so the mono date, the
    # avatar and the name share one centre line.
    PIECE = "inline-flex items-center h-5 leading-none"

    def initialize(created_at:, created_by: nil, updated_at: nil, updated_by: nil,
                   created_by_machine: false, updated_by_machine: false, test_id: nil, **options)
      @created_at = created_at
      @created_by = created_by
      @updated_at = updated_at
      @updated_by = updated_by
      @created_by_machine = created_by_machine
      @updated_by_machine = updated_by_machine
      @test_id = test_id
      @options = options
    end

    private

    def html_options
      merge_options(base_class: "flex flex-wrap items-center gap-x-5 gap-y-1.5", test_id: @test_id,
                    options: { aria: { label: t("ui.audit.title") } }.merge(@options).merge(data: foot_data))
    end

    # E22 — the strip closes the page: `ui--panel-edges` pushes its panel down to the frame.
    def foot_data = (@options[:data] || {}).merge(page_foot: true)

    def entries
      rows = [ [ :created, @created_at, @created_by, @created_by_machine ] ]
      rows << [ :updated, @updated_at, @updated_by, @updated_by_machine ] if updated?
      rows
    end

    # I caller passano sempre una data presente (created_at obbligatorio; il blocco Updated è reso
    # solo quando updated_at è presente), quindi niente safe-nav difensiva.
    def format_at(time) = time.strftime(DATE_FORMAT)

    # Iniziali (max 2 lettere) dal nome. Reso solo quando il nome è presente (guardia nel template).
    def initials(name) = name.to_s.split.map { |word| word[0] }.first(2).join.upcase

    def updated? = @updated_at.present?

    # L'avatar dell'autore: iniziali per una persona, icona per un'automazione.
    def author_avatar(name, machine:)
      classes = "shrink-0 inline-flex items-center justify-center w-5 h-5 rounded-full bg-stone-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 text-[9px] font-semibold"
      return tag.span(render(Ui::IconComponent.new(name: "bot", class: "text-[9px]")), class: classes, data: { test: "audit-author-machine" }) if machine

      tag.span(initials(name), class: classes)
    end
  end
end
