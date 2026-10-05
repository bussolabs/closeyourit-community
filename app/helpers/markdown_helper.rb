# frozen_string_literal: true

# Rendering markdown condiviso. Nato per le pagine Knowledge, oggi lo usa anche l'analisi tecnica
# del ticket (CYRA-259) e, tramite Ui::MarkdownComponent, ogni campo di testo libero dell'app
# (CYRA-261): sta qui, e non in KnowledgeHelper, perché un ticket non deve chiamare un helper di un
# dominio che non è il suo.
module MarkdownHelper
  # `escape: true` — il raw HTML del sorgente diventa TESTO VISIBILE (`&lt;div&gt;`) invece di sparire:
  # il default di Commonmarker (safe) lo sostituisce con `<!-- raw HTML omitted -->`, e in un commento
  # o in un'analisi tecnica "usa <div> per il layout" perdeva mezza frase senza dirlo. Sicuro come
  # prima: escapato non è eseguibile, e gli URL pericolosi (`javascript:`) restano neutralizzati.
  # `hardbreaks` è il default di Commonmarker 2: un a capo singolo resta un a capo (<br>), quindi un
  # testo scritto SENZA markdown si legge esattamente come prima di questo rendering.
  # `header_ids: nil` — niente àncora automatica dentro i titoli: nessuno la usa (non c'è un indice di
  # sezione da nessuna parte) e da CYRA-261 lo stesso markdown compare più volte nella STESSA pagina
  # (dieci commenti, dieci passi di lavorazione): due titoli uguali darebbero due id uguali.
  OPTIONS = { extension: { table: true, strikethrough: true, autolink: true, tasklist: true,
                           header_ids: nil },
              render: { escape: true } }.freeze

  # Markdown (GFM) → HTML. Commonmarker in modalità safe: nessuno script eseguibile in uscita e URL
  # pericolosi neutralizzati → l'output è sicuro da marcare html_safe senza un secondo sanitize (che
  # spoglierebbe le tabelle GFM).
  # Con `page:` i wikilink `[[Titolo]]` risolti diventano link veri prima della conversione
  # (Knowledge::Links::Render); senza, il markdown è reso tale e quale — è il caso degli snapshot
  # di cronologia, che non hanno un grafo proprio, e dell'analisi tecnica dei ticket. `links:`
  # restringe l'aggancio ai collegamenti che il lettore può davvero aprire.
  #
  # `remote_images: false` per i testi che scrive chiunque veda il progetto (l'analisi tecnica di un
  # ticket: aprire un ticket è baseline, non serve `tickets.edit`). Un'immagine remota nel markdown
  # è una richiesta che parte dal browser di CHI LEGGE — un tracking pixel che raccoglie IP, momento
  # della lettura e user-agent di ogni membro che apre la scheda. La CSP non ferma nulla: `img_src`
  # ammette `:https` ed è per giunta in report-only.
  def render_markdown(text, page: nil, links: nil, remote_images: true)
    source = page ? Knowledge::Links::Render.call(text: text, page: page, links: links) : text.to_s
    # Testo assente: si esce prima. `nil.to_s` è una stringa vuota US-ASCII e Commonmarker rifiuta
    # tutto ciò che non è UTF-8 (TypeError), quindi un campo mai compilato faceva esplodere la pagina.
    return "".html_safe if source.strip.empty?

    html = Commonmarker.to_html(source, options: OPTIONS)
    html = defuse_remote_images(html) unless remote_images
    mark_file_paths(decorate_code_blocks(html)).html_safe
  end

  # Stesso rendering, ma per il testo che vive DENTRO una riga già formattata dalla pagina (uno step
  # di scenario accanto alla sua etichetta, una voce di Definition of Done in un <li> con la sua
  # icona): il <p> che avvolge un testo di un blocco solo — il caso normale — verrebbe reso a blocco
  # e manderebbe il testo a capo sotto l'etichetta. Se invece il testo ha davvero più blocchi (un
  # elenco, due paragrafi) l'HTML resta intero: meglio un blocco dentro una riga che un elenco
  # appiattito in una frase sola.
  def render_markdown_inline(text, remote_images: true)
    html = render_markdown(text, remote_images: remote_images)
    fragment = Nokogiri::HTML5.fragment(html)
    blocks = fragment.children.reject { |node| node.text? && node.text.strip.empty? }
    return html unless blocks.one? && blocks.first.name == "p"

    blocks.first.inner_html.html_safe
  end

  private

  # Le immagini che punterebbero fuori (http/https, o protocol-relative `//host/x.png`) diventano il
  # loro indirizzo scritto in chiaro: l'informazione resta leggibile e non parte nessuna richiesta.
  # Restano intatte quelle a stessa origine (`/rails/active_storage/…`) e i data-uri, che non
  # chiamano nessuno. Gli screenshot veri vivono negli allegati del ticket, non qui dentro.
  def defuse_remote_images(html)
    fragment = Nokogiri::HTML5.fragment(html)
    fragment.css("img").each do |img|
      src = img["src"].to_s
      next unless src.match?(%r{\A(?:https?:)?//}i)

      label = [ img["alt"].presence, src ].compact.join(" — ")
      img.replace(Nokogiri::HTML5.fragment("<code></code>").tap { |f| f.at_css("code").content = label })
    end
    fragment.to_html
  end

  # CYRA-405 — nelle analisi tecniche i percorsi dei file sono scritti in mezzo alla prosa
  # («la logica sta in app/services/foo.rb:33»): chi non è del mestiere non ha appigli per capire
  # dove finisce la spiegazione e comincia il riferimento tecnico. Qui prendono il fondino del
  # codice, come se fossero stati scritti fra backtick.
  #
  # Solo il testo discorsivo: dentro code/pre/a non si tocca niente (lì il segno c'è già, o il testo
  # è un link). Nessun costo su un testo che di percorsi non ne ha: si esce al primo controllo.
  FILE_PATH = %r{\b[\w.\-/]+\.(?:rb|erb|js|css|yml|yaml|json|md|sql|rake|ru)(?::\d+)?\b}

  def mark_file_paths(html)
    return html unless html.match?(FILE_PATH)

    fragment = Nokogiri::HTML5.fragment(html)
    fragment.xpath(".//text()[not(ancestor::code or ancestor::pre or ancestor::a)]").each do |node|
      text = node.text
      next unless text.match?(FILE_PATH)

      # ESCAPE PRIMA, marcatura dopo: `nodo.text` restituisce il testo GREZZO (il `<script>` che il
      # renderer aveva reso innocuo torna a essere un tag), e rimetterlo così com'è lo farebbe
      # rivivere. I caratteri di un percorso non contengono nulla di speciale, quindi la ricerca
      # funziona identica sul testo già escapato.
      escaped = ERB::Util.html_escape(text).to_str
      node.replace(escaped.gsub(FILE_PATH) { |clean_path| "<code>#{clean_path}</code>" })
    end
    fragment.to_html
  end

  # CYRA-431 — una riga di comando più larga della colonna finiva tagliata al bordo: nessuna barra,
  # nessun segno che il testo continuasse, e chi copiava a mano portava via mezzo comando. Ora ogni
  # blocco di codice scorre in orizzontale, dichiara con una sfumatura che c'è altro da vedere
  # (stesso segnale delle tabelle larghe) e ha un bottone che copia la riga SORGENTE, intera: il
  # testo copiato non dipende da quanto se ne vede.
  def decorate_code_blocks(html)
    return html unless html.include?("<pre")

    fragment = Nokogiri::HTML5.fragment(html)
    fragment.css("pre").each do |pre|
      next if pre.parent&.[]("data-test") == "code-block"

      code = pre.at_css("code")
      next if code.nil?

      pre["class"] = [ pre["class"], "overflow-x-auto" ].compact.join(" ").strip
      pre["data-controller"] = "ui--scroll-hint"
      code["data-clipboard-target"] = "source"
      pre.replace(code_block_wrapper(pre))
    end
    fragment.to_html
  end

  # Il bottone resta fuori dal <pre> (dentro finirebbe nel testo copiato e scorrerebbe via col
  # contenuto) e compare al passaggio del mouse; da tastiera lo si raggiunge col focus.
  def code_block_wrapper(pre)
    wrapper = Nokogiri::HTML5.fragment(<<~HTML).at_css("div")
      <div class="group/code relative" data-controller="clipboard" data-test="code-block"
           data-clipboard-copied-value="#{ERB::Util.html_escape(I18n.t('shared.code_block.copied'))}">
        <button type="button" data-action="clipboard#copy" data-test="code-block-copy"
                class="absolute right-1.5 top-1.5 z-10 rounded border border-stone-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 px-1.5 py-0.5 text-[11px] font-medium text-gray-600 dark:text-zinc-400 opacity-0 transition group-hover/code:opacity-100 focus:opacity-100 hover:text-zinc-900 dark:hover:text-zinc-100">
          <span data-clipboard-target="label">#{ERB::Util.html_escape(I18n.t('shared.code_block.copy'))}</span>
        </button>
      </div>
    HTML
    wrapper.prepend_child(pre.dup)
    wrapper
  end
end
