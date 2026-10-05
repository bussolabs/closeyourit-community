# frozen_string_literal: true

require "rails_helper"

# CYRA-715: la Content Security Policy dell'area autenticata ora BLOCCA davvero. Un attributo
# `onclick="…"` scritto dentro l'HTML è codice inline che nessun nonce può autorizzare — la spec CSP
# non prevede modo di firmarlo, e `'unsafe-inline'` (o `'unsafe-hashes'`) riaprirebbe esattamente il
# buco che la policy esiste per chiudere.
#
# Il guasto che ne nasce è muto: la pagina si disegna intera, la riga si illumina al passaggio del
# mouse, e semplicemente non succede niente quando la si preme. Nessun 500, nessuna riga di log —
# solo una console del browser che nessuno guarda. Questo gate ferma il primo attributo che rientra,
# prima che qualcuno lo scopra da utente.
#
# La via giusta nel progetto è un controller Stimulus con `data-action`, che vive in un file .js
# servito dall'origine e quindi coperto da `script-src 'self'` (es. `ui--row-link`).
RSpec.describe "handler inline nelle view" do
  # I soli attributi che il browser esegue come codice. Non un `\son[a-z]+=` generico: `on` è un
  # prefisso comune anche fuori dagli eventi (un `data-` custom, un testo tradotto) e un gate che
  # sbaglia bersaglio si disattiva da solo alla prima falsa accusa.
  EVENTI_DOM = %w[
    onabort onblur onchange onclick oncontextmenu oncopy oncut ondblclick ondrag ondragend
    ondragenter ondragleave ondragover ondragstart ondrop onerror onfocus oninput oninvalid
    onkeydown onkeypress onkeyup onload onmousedown onmouseenter onmouseleave onmousemove
    onmouseout onmouseover onmouseup onpaste onreset onscroll onselect onsubmit ontoggle onwheel
  ].freeze

  # Solo i canali che la policy blocca. Il sito pubblico resta in sola segnalazione (le sue pagine
  # stanno in casa d'altri): quando passerà anche lui all'enforce, si aggiunge qui.
  CARTELLE_ENFORCED = %w[
    app/views/member app/views/valhalla app/views/account app/views/auth
    app/views/home app/views/errors app/views/cli
    app/views/layouts app/views/shared app/components
  ].freeze

  # Tre forme, tutte e tre eseguite dal browser come codice inline:
  #   attributo scritto a mano       <tr onclick="…">
  #   opzione simbolo a un helper    link_to …, onclick: "…"
  #   opzione stringa a un helper    link_to …, "onclick" => "…"
  # Le ultime due non hanno il segno di uguale dell'HTML, e la terza ha una virgoletta ATTACCATA
  # davanti al nome: un confine `\s` la mancherebbe e il gate resterebbe verde mentre la policy
  # blocca il gesto. Il lookbehind esclude invece i nomi che finiscono per uno di questi
  # (`data-onclick`, `my_onclick`), che non sono attributi evento.
  let(:regexp) { /(?<![\w-])(#{EVENTI_DOM.join('|')})\s*(=\s*["']|:\s*["']|"?\s*=>)/i }

  let(:file_sorgente) do
    CARTELLE_ENFORCED.flat_map { |cartella| Dir[Rails.root.join(cartella, "**/*.{erb,html,rb}")] }.sort
  end

  it "trova i file da controllare (se la lista si svuota il gate non prova più niente)" do
    expect(file_sorgente.size).to be > 100
  end

  it "nessuna view dell'area autenticata esegue codice scritto dentro un attributo HTML" do
    colpevoli = file_sorgente.filter_map do |percorso|
      righe = File.readlines(percorso).each_with_index.filter_map do |riga, indice|
        "#{Pathname.new(percorso).relative_path_from(Rails.root)}:#{indice + 1}" if riga.match?(regexp)
      end
      righe.presence
    end.flatten

    expect(colpevoli).to be_empty, <<~MESSAGGIO
      Attributi evento inline (onclick, onchange…) trovati qui:
        #{colpevoli.join("\n  ")}
      La CSP dell'area autenticata li blocca: la pagina si disegna ma il gesto non fa niente.
      Vale sia per l'attributo scritto a mano sia per l'opzione passata a un helper
      (`link_to …, onclick: "…"`). Sostituiscili con un controller Stimulus
      (`data-action="click->…"`).
    MESSAGGIO
  end
end
