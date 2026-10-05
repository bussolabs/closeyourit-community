# frozen_string_literal: true

require "rails_helper"

# CYRA-356 — LA VOCE DEL MENU E IL TITOLO DELLA PAGINA DICONO LA STESSA PAROLA.
#
# Nel menu laterale alcune voci restavano inglesi sopra pagine italiane («Replays» che apriva
# «Session replay»), e altre portavano un nome che nella pagina non compariva («Conversazioni» che
# apriva «Chat», «Personale» che apriva «Segreti personali»). Chi preme una voce perde così la
# conferma di essere arrivato dove voleva: deve fermarsi a capire se la pagina aperta è quella
# giusta o un'altra.
#
# Il guard segue il CODICE, non un elenco scritto a mano: legge le voci dichiarate in
# `Member::NavigationHelper`, risolve la pagina a cui portano e ne prende il titolo — l'h1 del
# `Ui::PageHeaderComponent`, che è ciò che si legge davvero, e solo in mancanza di quello il titolo
# della scheda del browser. Una voce nuova entra nel controllo da sola.
#
# Regola: la voce e il titolo condividono almeno una parola piena. Non pretende stringhe identiche,
# perché un titolo può qualificare («Membri» → «Membri del team»); pretende che la parola con cui si
# è premuto ricompaia in cima alla pagina.
#
# La seconda regola è quella del glossario (`docs/glossario-prodotto.md`): una voce che si legge
# uguale in italiano e in inglese è una traduzione mancante, a meno che non sia un nome proprio del
# prodotto — e allora sta dichiarata qui sotto, con la ragione.
RSpec.describe "Voci di menu e titoli di pagina (CYRA-356)", type: :model do
  # CYRA-742 ha diviso il menu in una parte per macro-sezione: il guard leggeva ancora il solo file
  # d'ingresso, che di voci non ne ha più nessuna, e girava a vuoto senza dirlo — l'esempio «non gira
  # a vuoto» esiste apposta per accorgersene. Si legge la cartella, non un file: una parte nuova entra
  # nel controllo da sola.
  HELPER_NAV = Rails.root.glob("app/helpers/member/nav_*_items_helper.rb").sort.freeze

  # Voci che non possono avere il titolo della loro pagina, con la ragione. Sono tre e nessuna è un
  # difetto di nome: due portano a una pagina che si intitola da sé, una è un filtro.
  SENZA_TITOLO_PROPRIO = {
    # La Home accoglie con un saluto («Bentornato, …»), non con il proprio nome.
    "member.nav.home" => "la Home saluta, non si intitola",
    # La panoramica prende il nome dall'area che apre: il titolo è deciso a runtime dal gruppo.
    "member.nav.overview" => "il titolo è il nome dell'area, scelto a runtime",
    # «Il mio lavoro» è la lista dei ticket con un filtro già acceso, non una seconda pagina.
    "member.nav.my_work" => "è la lista dei ticket filtrata, non un'altra pagina"
  }.freeze

  # Voci il cui indirizzo non si risolve leggendo il codice, perché lo sceglie un metodo in base ai
  # permessi. Qui si dichiara la pagina di riferimento, così la voce resta nel controllo.
  VISTE_ESPLICITE = {
    "organization_vault_path" => "member/shared_secrets/index"
  }.freeze

  # I nomi che restano uguali nelle due lingue di proposito: nomi propri con cui la cosa è conosciuta
  # in tutto il prodotto, non parole rimaste da tradurre. Ogni altra uguaglianza è un buco.
  NOMI_PROPRI = {
    "member.nav.home" => "l'area si chiama Home in ogni lingua (glossario)",
    "member.nav.overview" => nil,
    "member.nav.uptime" => "Uptime è il nome della misura, si legge così anche in italiano",
    "member.nav.performance" => "Performance è entrato in italiano come nome della misura",
    "member.nav.guidance" => "Guidance è il nome della funzione: menu, titolo, scheda e pulsanti"
    # CYRA-581/CYRA-545 — «member.nav.github_app» non è più una voce del menu: al suo posto c'è
    # «Integrazioni», l'elenco dei servizi collegabili, e la GitHub App è una delle sue schede. Il
    # nome resta in i18n perché è quello con cui il changelog nomina quell'area, ma qui non ha più
    # niente da dichiarare: il guard legge le voci dichiarate nel menu, e quella non c'è.
    # CYRA-584 — «member.nav.replays» non è più uguale nelle due lingue: il nome canonico «Session
    # replay» resta (titolo di pagina, impostazioni del progetto, sito), ma nel menu lo segue la
    # parola con cui la funzione si CERCA — «registrazioni», «recordings» — che è tradotta.
    # CYRA-535 — «member.nav.seo» non è più una voce: SEO è il nome dell'AREA (member.nav.group_seo),
    # e le sue quattro voci hanno nomi italiani. I nomi delle aree li presidia il glossario.
  }.compact.freeze

  # Parole troppo comuni per dire che due nomi parlano della stessa cosa: se l'unico incontro fra
  # voce e titolo è «della», i due nomi sono diversi. La soglia è tre lettere, non quattro, perché
  # «Log» è un nome intero.
  PAROLE_VUOTE = %w[
    della dello delle degli dell alla alle allo agli sulla sulle come sono tuo tua tuoi tue
    del dei che con per una uno non nel nei the and for you your with from that this
  ].freeze

  def voci_dichiarate
    sorgente_nav.scan(/label:\s*"([\w.]+)",\s*path:\s*([a-z_]+_path)/m).uniq
  end

  def sorgente_nav = HELPER_NAV.map(&:read).join("\n")

  # Il titolo che si legge in cima alla pagina. In ordine: l'h1 dell'header standard, lo stesso h1
  # dentro il partial di intestazione (le pagine a pannelli lo tengono lì), e come ultima risorsa il
  # titolo della scheda del browser.
  def chiave_titolo(vista)
    directory = vista.dirname
    candidati = [ vista, *Dir[directory.join("_header*.html.erb")].sort.map { |f| Pathname(f) } ]
    da_header = candidati.filter_map { |file| h1_key(file) }.first
    return da_header if da_header

    vista.exist? ? vista.read[/content_for\s+:title,\s*t\(["']([\w.]+)["']/, 1] : nil
  end

  def h1_key(file)
    return nil unless file.exist?

    file.read[/PageHeaderComponent\.new\(\s*\n?\s*title:\s*t\(["']([\w.]+)["']/m, 1]
  end

  # Vista che serve una voce: dalla route del suo indirizzo, o dalla dichiarazione esplicita quando
  # l'indirizzo lo sceglie un metodo.
  def vista_per(helper_path)
    if VISTE_ESPLICITE.key?(helper_path)
      return Rails.root.join("app/views/#{VISTE_ESPLICITE.fetch(helper_path)}.html.erb")
    end

    route = Rails.application.routes.routes.find { |r| r.name == helper_path.delete_suffix("_path") }
    return nil unless route

    Rails.root.join("app/views/#{route.defaults[:controller]}/#{route.defaults[:action]}.html.erb")
  end

  def parole(testo)
    testo.downcase.split(/[^[[:alpha:]]]+/).reject { |p| p.size < 3 || PAROLE_VUOTE.include?(p) }
  end

  it "il guard legge tutte le voci dichiarate nel menu (non gira a vuoto)" do
    expect(HELPER_NAV).not_to be_empty
    dichiarate = sorgente_nav.scan(/label:\s*"[\w.]+",\s*path:/).size

    expect(voci_dichiarate.size).to eq(dichiarate)
    expect(voci_dichiarate.size).to be > 40
  end

  %i[it en].each do |lingua|
    it "ogni voce del menu ha un nome in #{lingua}" do
      senza_nome = voci_dichiarate.map(&:first).uniq.reject do |chiave|
        I18n.t(chiave, locale: lingua, default: nil).present?
      end

      expect(senza_nome).to be_empty, "voci di menu senza testo in #{lingua}: #{senza_nome.join(', ')}"
    end

    it "in #{lingua} ogni voce del menu dice la stessa parola del titolo della pagina che apre" do
      diverse = voci_dichiarate.filter_map do |chiave, helper_path|
        next if SENZA_TITOLO_PROPRIO.key?(chiave)

        vista = vista_per(helper_path)
        next if vista.nil?

        chiave_h1 = chiave_titolo(vista)
        next if chiave_h1.nil?

        voce = I18n.t(chiave, locale: lingua, default: "")
        titolo = I18n.t(chiave_h1, locale: lingua, default: "")
        prossimo = (parole(voce) & parole(titolo)).any?
        "#{chiave}: la voce dice «#{voce}», la pagina «#{titolo}»" unless prossimo
      end

      expect(diverse).to be_empty, "voci che non si ritrovano nel titolo della loro pagina:\n#{diverse.join("\n")}"
    end
  end

  it "solo i nomi propri del prodotto si leggono uguali in italiano e in inglese" do
    uguali = voci_dichiarate.map(&:first).uniq.select do |chiave|
      I18n.t(chiave, locale: :it, default: "") == I18n.t(chiave, locale: :en, default: "")
    end

    expect(uguali).to match_array(NOMI_PROPRI.keys),
                      "voci rimaste in inglese (o nomi propri non dichiarati): " \
                      "#{(uguali - NOMI_PROPRI.keys).join(', ')}"
  end

  # Le schede della pagina d'ingresso di un'area portano alle STESSE pagine del menu: se le chiamano
  # in un altro modo, la stessa cosa finisce con tre nomi — la scheda, la voce, il titolo. Le chiavi
  # delle schede sono già quelle del menu, quindi il confronto si ricava da solo.
  describe "le schede delle panoramiche chiamano le pagine come il menu" do
    def schede(lingua)
      I18n.t("member.overviews", locale: lingua).flat_map do |_area, contenuto|
        next [] unless contenuto.is_a?(Hash)

        contenuto.filter_map do |chiave, valore|
          next unless valore.is_a?(Hash) && valore[:label].is_a?(String)

          voce = I18n.t("member.nav.#{chiave}", locale: lingua, default: nil)
          [ chiave, valore[:label], voce ] if voce
        end
      end
    end

    %i[it en].each do |lingua|
      it "in #{lingua} nessuna scheda inventa un secondo nome" do
        diverse = schede(lingua).reject { |_, scheda, voce| scheda == voce }
                                .map { |chiave, scheda, voce| "#{chiave}: scheda «#{scheda}», menu «#{voce}»" }

        expect(diverse).to be_empty, "schede che non si chiamano come il menu:\n#{diverse.join("\n")}"
      end
    end

    it "il controllo guarda davvero qualche scheda" do
      expect(schede(:it).size).to be >= 5
    end
  end

  # Il rilievo che ha aperto il ticket: nel menu si leggeva il segnaposto di i18n al posto di un nome.
  it "nessuna voce del menu mostra un avviso di traduzione mancante" do
    segnaposti = voci_dichiarate.map(&:first).uniq.flat_map do |chiave|
      %i[it en].filter_map do |lingua|
        testo = I18n.t(chiave, locale: lingua, default: "")
        "#{chiave} (#{lingua})" if testo.include?("translation missing")
      end
    end

    expect(segnaposti).to be_empty
  end
end
