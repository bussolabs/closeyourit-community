# frozen_string_literal: true

require "rails_helper"
require "ripper"

# CYRA-748 — il design system aveva i mattoni piccoli (bottoni, tabelle, chip) e nessuno di
# impaginazione: pila, griglia, sezione, elenco descrittivo. Così le pagine grandi erano scritte a
# mano, e le stesse dieci righe di markup si ripetevano a centinaia — 668 superfici card, 280
# intestazioni di sezione, 170 etichette monospazio. La scheda di un errore misurava 552 righe: per
# cambiare un pannello si apriva lo stesso file di chi ne cambiava un altro.
#
# Qui si guarda il SORGENTE, non il comportamento: che ogni pagina abbia una misura leggibile e che
# i mattoni esistano davvero. Le prove di comportamento restano i request spec delle aree, che sono
# la rete vera di questa divisione.
RSpec.describe "Nessuna pagina fa tutto da sola", type: :model do
  # Il tetto della Definition of Done. Non è un numero estetico: sopra questa misura una pagina
  # smette di avere una forma leggibile in una schermata e torna a essere il posto in cui finisce
  # tutto, che è esattamente il problema.
  let(:tetto_righe) { 200 }

  # CYRA-802 — il tetto sulle righe non dice niente sulla FORMA: un partial di ottanta righe con
  # cinque condizioni una dentro l'altra si legge peggio di una pagina lunga e piatta. Quattro
  # livelli bastano per una lista dentro un ramo dentro un guardiano; il quinto è il segno che il
  # pezzo dentro ha un compito suo e vuole un partial.
  TETTO_PROFONDITA = 4

  # Conta solo ciò che RAMIFICA — condizioni e cicli — perché è quello che il lettore deve tenere a
  # mente per sapere se una riga viene resa. I blocchi che rendono markup (`render … do`, gli slot
  # `with_*`, `link_to … do`) sono struttura, come i tag HTML, e non contano.
  TAG_ERB = /<%(={1,2}|-|\#|%)?(.*?)[-=]?%>/m
  APRE_CONTROLLO = /\A(if|unless|case|while|until|for)\b/
  CONTINUA_CONTROLLO = /\A(else|elsif|when|in|rescue|ensure)\b/
  # Il ciclo dev'essere l'ULTIMA chiamata prima del `do`: `render(… @roles.map { … }) do` rende
  # markup, e il `map` che porta dentro non annida niente di ciò che segue.
  APRE_CICLO = /\.(each\w*|map|flat_map|filter_map|select|reject|sort_by|group_by|times|upto|
                  downto|step|sum|reduce|inject|partition|find|detect|count|cycle)\b
                (\s*\([^)]*\))?\s+do\b(\s*\|[^|]*\|)?\s*\z/x

  # Pagine, partial e template dei componenti: tutto ciò che si legge come markup, e quindi tutto
  # ciò che i due tetti misurano.
  let(:viste) {
    Rails.root.glob("app/views/**/*.erb").concat(Rails.root.glob("app/components/**/*.erb")).sort
  }

  it "nessuna pagina supera le duecento righe" do
    sopra = viste.filter_map { |file|
      misura = file.readlines.size
      "#{file.relative_path_from(Rails.root)} (#{misura})" if misura > tetto_righe
    }

    expect(sopra).to be_empty,
                     "Queste pagine superano le #{tetto_righe} righe: #{sopra.join(', ')}. " \
                     "Quello che è cresciuto va in un partial con un compito suo, o nei mattoni " \
                     "di impaginazione del design system."
  end

  # I mattoni nominati dal ticket. Esistono come componenti veri, non come classi copiate a mano in
  # ogni pagina: è la metà della Definition of Done che il tetto sulle righe da solo non presidia —
  # senza di loro le pagine tornerebbero a scrivere la stessa grafia in venti posti diversi.
  {
    "impila e mette in riga" => "Ui::StackComponent",
    "dispone a colonne che crescono con la larghezza" => "Ui::GridComponent",
    "disegna la superficie con l'intestazione titolata" => "Ui::SectionComponent",
    "elenca le coppie etichetta/valore" => "Ui::DescriptionListComponent"
  }.each do |compito, nome|
    it "il mattone che #{compito} esiste ed è caricabile" do
      expect(Object.const_defined?(nome)).to be(true), "#{nome} non esiste."
    end
  end

  # Le grafie che i mattoni emettono sono quelle che le pagine avevano già scritte a mano: se un
  # componente ne emettesse una diversa, le pagine cambierebbero aspetto mentre il ticket dice il
  # contrario. Qui si congelano le tre che si ripetono di più.
  it "i mattoni emettono la grafia che le pagine avevano già" do
    expect(Ui::SectionComponent::TONES[:default][:surface]).to eq("border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900")
    expect(Ui::SectionComponent::HEADINGS[:base]).to eq("font-display text-[14px] font-semibold text-zinc-900 dark:text-zinc-100")
    expect(Ui::SectionComponent::HEADER_PADDINGS[:normal]).to eq("px-4 py-3")
    expect(Ui::DescriptionListComponent::LABEL)
      .to eq("font-mono uppercase text-[9.5px] tracking-[1.2px] text-gray-500 dark:text-zinc-400")
  end

  # La trappola dei mattoni, e il motivo per cui le mappe sono scritte per esteso: lo scanner di
  # Tailwind legge il SORGENTE e non vede una classe composta con l'interpolazione. Una `gap-#{n}`
  # non finirebbe nel foglio di stile, e la pagina uscirebbe senza spazi — un guasto che nessun
  # test di comportamento vede, perché l'HTML resta identico.
  {
    "Ui::StackComponent" => %w[COLUMN_GAPS ROW_GAPS],
    "Ui::GridComponent" => %w[COLS SM_COLS MD_COLS LG_COLS XL_COLS GAPS GAPS_Y GAPS_X],
    "Ui::SectionComponent" => %w[HEADINGS HEADER_PADDINGS HEADER_LAYOUTS],
    "Ui::DescriptionListComponent" => %w[SPANS]
  }.each do |componente, mappe|
    it "#{componente} scrive le classi per esteso, mai interpolate" do
      sorgente = Rails.root.join("app/components/ui/#{componente.demodulize.underscore}.rb").read
      interpolate = mappe.select { |mappa|
        blocco = sorgente[/#{mappa}\s*=\s*\{(.*?)\}\.freeze/m, 1]
        blocco.nil? || blocco.include?('#{')
      }

      expect(interpolate).to be_empty,
                             "Queste mappe di #{componente} costruiscono la classe invece di scriverla: " \
                             "#{interpolate.join(', ')}. Tailwind non la vedrebbe."
    end
  end

  # Se il tag apre un blocco lo dice il parser di Ruby, non una regex: un frammento che diventa
  # valido aggiungendo `end` è un blocco che si apre. Un tag che sta già in piedi da solo — `<%= x if
  # y %>`, un `case … end` intero dentro un attributo — non annida niente di ciò che viene dopo.
  #
  # `<% case x %>` va provato con un ramo dentro: `case x` seguito solo da `end` non è codice valido
  # nemmeno per Ruby, e senza questa seconda prova il `case` non risulterebbe aperto mentre il suo
  # `<% end %>` chiuderebbe lo stesso — mangiando un livello vero, quello che lo contiene.
  def apre_blocco?(codice)
    return false unless Ripper.sexp(codice).nil?

    !Ripper.sexp("#{codice}\nend").nil? || !Ripper.sexp("#{codice}\nwhen nil\nend").nil?
  end

  # La pila tiene TUTTI i blocchi aperti, non solo quelli che contano: un `<% end %>` chiude anche il
  # `render … do` che lo precede, e senza tenerne traccia il conto si sfalsa dal primo blocco di
  # rendering in poi.
  def profondita_annidamento(sorgente)
    pila = []
    massima = 0
    riga_massima = nil

    sorgente.scan(TAG_ERB) do
      tag = Regexp.last_match
      next if [ "#", "%" ].include?(tag[1])

      codice = tag[2].to_s.strip
      next if codice.empty? || codice.match?(CONTINUA_CONTROLLO)

      if apre_blocco?(codice)
        pila.push(codice.match?(APRE_CONTROLLO) || codice.match?(APRE_CICLO))
      elsif codice.match?(/\Aend\b/)
        pila.pop
      end

      next unless pila.count(true) > massima

      massima = pila.count(true)
      riga_massima = sorgente[0, tag.begin(0)].count("\n") + 1
    end

    [ massima, riga_massima, pila.size ]
  end

  it "nessuna parte di pagina annida più di quattro condizioni" do
    sopra = viste.filter_map { |file|
      profondita, riga = profondita_annidamento(file.read)
      "#{file.relative_path_from(Rails.root)}:#{riga} (#{profondita})" if profondita > TETTO_PROFONDITA
    }

    expect(sopra).to be_empty,
                     "Queste parti di pagina annidano più di #{TETTO_PROFONDITA} fra condizioni e cicli: " \
                     "#{sopra.join(', ')}. Il pezzo più interno ha un compito suo: va in un partial, " \
                     "o nei mattoni di impaginazione del design system."
  end
  # La prova che il conto sopra vale qualcosa: se un blocco restasse aperto a fine file il
  # misuratore starebbe leggendo il markup in modo diverso da come lo legge Rails, e la profondità
  # sarebbe un numero a caso.
  it "in ogni vista i blocchi aperti si chiudono tutti" do
    aperte = viste.filter_map { |file|
      _profondita, _riga, residuo = profondita_annidamento(file.read)
      "#{file.relative_path_from(Rails.root)} (#{residuo})" unless residuo.zero?
    }

    expect(aperte).to be_empty,
                      "Queste viste lasciano un blocco aperto: #{aperte.join(', ')}."
  end

  # Il misuratore ha una sua rete, perché un errore suo non si vede: direbbe un numero più basso e
  # la guardia tacerebbe. Ogni riga è un modo diverso di scrivere un blocco, col conto che deve dare.
  {
    "conta le condizioni annidate" => [ "<% if a %><% if b %>x<% end %><% end %>", 2 ],
    "conta i cicli" => [ "<% lista.each do |x| %><% if x %>y<% end %><% end %>", 2 ],
    "non conta i blocchi che rendono markup" =>
      [ "<%= render X.new do %><% if a %>x<% end %><% end %>", 1 ],
    "non conta il ciclo che sta dentro gli argomenti di un render" =>
      [ "<%= render X.new(o: lista.map { |x| x }) do %><% if a %>x<% end %><% end %>", 1 ],
    "non conta un tag che sta in piedi da solo" => [ "<%= x if a %><% if b %>y<% end %>", 1 ],
    "chiude il case aperto su più tag" =>
      [ "<% if a %><% case b %><% when 1 %>x<% end %><% end %><% if c %>y<% end %>", 2 ]
  }.each do |caso, (frammento, atteso)|
    it "il misuratore #{caso}" do
      profondita, _riga, residuo = profondita_annidamento(frammento)

      expect(profondita).to eq(atteso)
      expect(residuo).to be_zero
    end
  end
end
