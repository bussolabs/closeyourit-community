# frozen_string_literal: true

module Ui
  # Rende UNA release del changelog: intestazione (versione + data, dati grezzi in mono) e le
  # sezioni (Added/Changed/Fixed/…) con le loro voci. Riusato dal modale in sidebar
  # (Ui::ChangelogComponent) e dalla pagina storico completo.
  class ChangelogReleaseComponent < BaseComponent
    # CYRA-693 — oltre questa lunghezza la voce si presenta ripiegata: lead più prima frase, il
    # resto dietro «continua». È la stessa soglia della convenzione di scrittura (max 300 caratteri
    # a voce): sotto, la piega sarebbe solo rumore.
    FOLD_THRESHOLD = 300

    # I codici ticket tra parentesi, «(CYRA-850)» o «(CYRA-803, CYCL-62)»: chi legge le novità non
    # li usa, restano nel file per chi sviluppa.
    TICKET_CODES = /\s*\((?:[A-Z][A-Z0-9]{1,5}-\d+(?:,\s*)?)+\)/

    def initialize(release:)
      @release = release
    end

    private

    # [parte visibile, resto] di una voce: le voci corte non si piegano (resto nil); quelle lunghe
    # si tagliano alla prima fine di frase dopo il lead in grassetto. Senza un punto su cui tagliare
    # la voce resta intera: meglio lunga che mutilata a metà frase.
    def fold(item)
      return [ item, nil ] if item.length <= FOLD_THRESHOLD

      lead_end = (lead = item.match(/\A\*\*.+?\*\*:?\s*/)) ? lead.end(0) : 0
      cut = item.index(". ", lead_end)
      return [ item, nil ] unless cut

      [ item[0..cut], item[(cut + 1)..].strip ]
    end

    def section_label(label)
      t("shared.changelog.sections.#{label.downcase}", default: label)
    end

    # Rende il grassetto `**...**` come <strong> e i link markdown SOLO interni `[testo](/path)`
    # come <a> navigabili. L'href deve iniziare con "/" ma NON con "//" o "/\\" (esclude alla fonte
    # i link esterni, i protocol-relative e gli schemi pericolosi). Tutto il resto è testo:
    # escape + sanitize (contenuto nostro, ma igiene comunque).
    #
    # CYRA-445 — dove il link porta a un'area del prodotto, il nome mostrato è quello che l'area ha
    # nel menu, non quello scritto nel file: «Disponibilità», «Uptime» e «monitor» erano tre nomi per
    # la stessa voce di menu. Il file non si tocca (glossario: si rinomina la resa, mai il dato), e i
    # rimandi alle guide restano la parola con cui sono scritti.
    def inline(text)
      html = ERB::Util.html_escape(text.gsub(TICKET_CODES, ""))
      html = html.gsub(%r{\*\*(.+?)\*\*}m, '<strong>\1</strong>')
      html = html.gsub(Changelog::Areas::INTERNAL_LINK) do
        label, href = Regexp.last_match(1), Regexp.last_match(2)
        %(<a href="#{href}">#{ERB::Util.html_escape(Changelog::Areas.label_for_path(href) || label)}</a>)
      end
      helpers.sanitize(html, tags: %w[strong a], attributes: %w[href])
    end
  end
end
