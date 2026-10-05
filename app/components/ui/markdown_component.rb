# frozen_string_literal: true

module Ui
  # Testo libero scritto in markdown → HTML reso (CYRA-261). Un solo componente per tutti i campi che
  # riempiono persone, riga di comando e agenti (descrizione e commenti di un ticket, piano e passi
  # della lavorazione, idee, chat, aggiornamenti di un disservizio): prima ognuno stampava il grezzo
  # con `whitespace-pre-line` e si leggevano asterischi e cancelletti.
  #
  # `remote_images: false` DI DEFAULT, al contrario dell'helper: qui il testo lo scrive qualcun altro
  # e lo legge chiunque apra la pagina — un'immagine remota sarebbe una richiesta che parte dal
  # browser di chi legge (tracking pixel: IP, momento della lettura, user-agent). Chi ha davvero
  # bisogno delle immagini remote lo chiede esplicitamente.
  #
  # Due forme:
  # - blocco (default) — contenitore `prose` con i margini compattati alla densità dell'app;
  # - `inline: true` — <span> senza `prose`, così colore e corpo del testo restano quelli della riga
  #   che lo ospita (un'etichetta grigia resta grigia); vengono stilati solo gli elementi che il
  #   markdown può produrre in linea.
  class MarkdownComponent < BaseComponent
    include MarkdownHelper
    include MarkdownAnchorsHelper

    # `max-w-none`: la misura la decide il contenitore della pagina, non il plugin typography (nelle
    # colonne larghe l'analisi tecnica del ticket usa già la sua `max-w-[70ch]` passandola dal caller).
    # I margini di prose sono tarati su una pagina di documentazione: qui vanno stretti, o una nota di
    # due righe diventa alta il doppio della riga che la contiene.
    # Ultima riga: una voce di checklist (`- [x] fatto`) ha già la sua casella — col pallino
    # dell'elenco accanto si leggono due marcatori per la stessa riga.
    #
    # `prose-code:before/after:content-none`: il plugin typography stampa un backtick VERO prima e dopo
    # ogni <code>. Su una pagina di documentazione è una scelta; qui il testo arriva da chi ha scritto
    # `foo.rb` in markdown, e vedersi tornare indietro i backtick è esattamente il difetto che questo
    # lavoro elimina. Il codice si segna col fondino, come nella variante inline.
    BLOCK = "prose prose-stone prose-sm max-w-none prose-headings:font-display prose-code:font-mono " \
            "prose-code:before:content-none prose-code:after:content-none prose-code:font-normal " \
            "prose-code:bg-stone-100 dark:prose-code:bg-zinc-800 dark:prose-code:text-zinc-100 prose-code:rounded prose-code:px-1 prose-code:py-px " \
            "[&_pre_code]:bg-transparent [&_pre_code]:px-0 " \
            "prose-p:my-2 prose-headings:mt-3.5 prose-headings:mb-1.5 prose-ul:my-2 prose-ol:my-2 " \
            "prose-li:my-0.5 prose-pre:my-2.5 prose-blockquote:my-2.5 prose-hr:my-3.5 " \
            "prose-table:my-2.5 [&>*:first-child]:mt-0 [&>*:last-child]:mb-0 " \
            "[&_li:has(input[type=checkbox])]:list-none"

    # Un elemento a blocchi in testa all'output: dice che il markdown non è restato "in linea".
    # `div` = il contenitore che avvolge un blocco di codice (CYRA-431): il markdown non ne produce
    # altri, e un blocco di codice dentro uno <span> resterebbe senza il suo bottone di copia.
    BLOCK_TAGS = /<(?:p|ul|ol|table|pre|blockquote|h[1-6]|hr|div)[\s>]/i

    INLINE = "[&_strong]:font-semibold [&_em]:italic [&_del]:line-through " \
             "[&_code]:font-mono [&_code]:text-[0.92em] [&_code]:bg-stone-100 dark:[&_code]:bg-zinc-800 [&_code]:rounded " \
             "[&_code]:px-1 [&_code]:py-px [&_a]:text-indigo-600 dark:[&_a]:text-indigo-400 [&_a]:underline " \
             "[&_a]:decoration-indigo-200 dark:[&_a]:decoration-indigo-500/60 [&_a]:underline-offset-2 " \
             "[&_ul]:list-disc [&_ol]:list-decimal [&_ul]:pl-4 [&_ol]:pl-4 [&_p]:my-0"

    # `page:`/`links:` servono solo alla Knowledge, dove i wikilink `[[Titolo]]` vanno risolti in link
    # veri prima della conversione (e ristretti a quelli che il lettore può davvero aprire).
    # `anchor_prefix:` gives h1–h3 ids (`<prefix>-<slug>`) for an index of sections. CYRA-883
    # `short_links:` turns a bare link (text equal to its address) into its site name, for answers that
    # list sources as raw URLs (Coworkers, CYRA-992). Written link text is never touched.
    def initialize(text:, inline: false, test_id: nil, remote_images: false, page: nil, links: nil,
                   anchor_prefix: nil, short_links: false, **options)
      @text = text
      @short_links = short_links
      @anchor_prefix = anchor_prefix
      @inline = inline
      @test_id = test_id
      @remote_images = remote_images
      @page = page
      @links = links
      @options = options
    end

    private

    # `max-w-none` è il default (la misura la decide la pagina), ma sparisce se il caller ne porta una
    # sua: due `max-w-*` sullo stesso elemento non si sommano, vince quella scritta più avanti nel CSS
    # generato — e sarebbe `max-w-none`, cioè la riga di testo lunga quanto la colonna, proprio dove
    # (Knowledge, analisi tecnica) si era scelta una misura leggibile.
    def html_options
      base = @inline ? INLINE : BLOCK
      base = base.sub(" max-w-none", "") if Array(@options[:class]).join(" ").match?(/\bmax-w-/)
      merge_options(base_class: base, test_id: @test_id, options: @options)
    end

    # Il contenitore esce anche col testo vuoto: i `data-test` ci restano agganciati (li usano gli
    # spec di sistema) e le pagine che vogliono un empty state proprio lo decidono già a monte.
    def rendered
      @rendered ||=
        if @text.to_s.strip.blank?
          "".html_safe
        elsif @inline
          render_markdown_inline(@text, remote_images: @remote_images)
        elsif @anchor_prefix
          anchor_headings(render_markdown(@text, page: @page, links: @links, remote_images: @remote_images),
                          prefix: @anchor_prefix)
        elsif @short_links
          shorten_links(render_markdown(@text, page: @page, links: @links, remote_images: @remote_images))
        else
          render_markdown(@text, page: @page, links: @links, remote_images: @remote_images)
        end
    end

    SHORT_LINK = "no-underline! whitespace-nowrap rounded-full border border-stone-200 dark:border-zinc-700 " \
                 "px-1.5 text-[11.5px] hover:bg-indigo-50 dark:hover:bg-indigo-500/15"

    def shorten_links(html)
      fragment = Nokogiri::HTML5.fragment(html)
      fragment.css("a[href^='http']").each do |link|
        next unless link.text.strip == link["href"]

        host = URI.parse(link["href"]).host.to_s.delete_prefix("www.")
        next if host.empty?

        link["title"] = link["href"]
        link["class"] = SHORT_LINK
        link.content = "#{host} ↗"
      rescue URI::InvalidURIError
        next
      end
      fragment.to_html.html_safe
    end

    # `inline` chiede uno <span>, ma lo ottiene solo se il testo è davvero rimasto in linea: quando
    # ha più blocchi (due paragrafi, un elenco) `render_markdown_inline` restituisce l'HTML intero, e
    # un <ul> dentro uno <span> dentro un <p> fa chiudere il paragrafo al parser — lo span viene
    # riaperto dopo, il contenuto esce dal contenitore e le classi si perdono per strada.
    def wrapper_tag
      @inline && !rendered.match?(BLOCK_TAGS) ? :span : :div
    end
  end
end
