# frozen_string_literal: true

require "rails_helper"
require "prism"

# CYRA-759 — una request spec confrontava l'HTML della pagina col nome letto dal record:
# `expect(response.body).to include(reader.name)`. Il nome veniva da Faker, e quando esce con
# l'apostrofo — «Jonas O'Kon» — la pagina lo scrive giustamente `Jonas O&#39;Kon`: il confronto
# fallisce su una pagina corretta. Rosso il 2026-09-02 sullo shard 8 di una PR che toccava solo il
# README, verde al secondo giro: il peggior tipo di guasto, quello che non si riproduce.
#
# Non è un caso raro da trascurare. Misurato sui generatori che il parco factory usa davvero per i
# nomi: `Faker::Name.name` produce un carattere da escapare 81 volte su 5000 (1,6%),
# `Faker::Company.name` 125 su 5000 (2,5%). Con qualche decina di esempi che leggono un nome, un
# rosso a caso ogni poche settimane è la normalità, non l'eccezione.
#
# La regola che ne esce non ha bisogno di sapere da dove venga il valore: **il testo che ci si
# aspetta dentro l'HTML si SCRIVE, non si rilegge dal record**. Un letterale dice al lettore cosa
# deve comparire nella pagina, e non cambia sotto i piedi. Dove il testo va provato proprio nella
# sua forma HTML, si avvolge in `ERB::Util.html_escape`.
#
# CONFINE — il gate guarda il solo attributo `name`. È lì che stanno tutti i generatori del parco
# factory capaci di produrre `'`, `&`, `<`: i nomi di persona e di organizzazione. `title`, `body` e
# `description` nascono da `Faker::Lorem`, che genera parole latine e nient'altro (0 su 3000): non
# sono fragili, e allargare il divieto a loro vorrebbe dire riscrivere una quarantina di asserzioni
# sane. `full_name`, `hostname`, `label` sono nomi di metodo diversi e restano fuori.
RSpec.describe "nomi confrontati con l'HTML grezzo nelle prove" do
  # Le forme con cui il progetto scrive «questo testo lo voglio come lo rende la pagina».
  # Metodo e non costante: una costante scritta in un blocco RSpec finisce su `Object`
  # (spec/config/spec_constants_leak_spec.rb), e un nome generico se lo contenderebbe con altri.
  def escape_html?(nome) = %i[html_escape escapeHTML escape_once h].include?(nome)

  # Si legge l'ALBERO, non il testo. Una regex su `response.body` non sa distinguere l'asserzione
  # sull'HTML grezzo da `Nokogiri::HTML(response.body).text`, che il nome lo de-escapa e quindi è
  # sempre corretta; né sa dire se il `.name` che vede sta già dentro `html_escape`.
  def nomi_grezzi(sorgente, etichetta)
    risultato = Prism.parse(sorgente)
    return [ "#{etichetta} — sorgente non analizzabile: #{risultato.errors.first&.message}" ] if risultato.failure?

    trovati = []
    visita = lambda do |nodo|
      trovati.concat(offese_del_confronto(nodo, etichetta)) if confronto_sul_body?(nodo)
      nodo.compact_child_nodes.each { |figlio| visita.call(figlio) }
    end
    visita.call(risultato.value)
    trovati
  end

  # `expect(response.body).to ...` / `.not_to ...`: il receiver dell'asserzione dev'essere ESATTAMENTE
  # il corpo della risposta. `expect(Nokogiri::HTML(response.body).text)` ha per receiver la `.text`,
  # e infatti non ha il problema.
  def confronto_sul_body?(nodo)
    return false unless nodo.is_a?(Prism::CallNode) && %i[to not_to].include?(nodo.name)

    expect = nodo.receiver
    return false unless expect.is_a?(Prism::CallNode) && expect.name == :expect

    argomento = expect.arguments&.arguments&.first
    argomento.is_a?(Prism::CallNode) && argomento.name == :body &&
      argomento.receiver.is_a?(Prism::CallNode) && argomento.receiver.name == :response
  end

  # Dentro il matcher: ogni `.name` che non sia già passato da un escape HTML.
  def offese_del_confronto(nodo, etichetta)
    offese = []
    visita = lambda do |figlio, protetto|
      if figlio.is_a?(Prism::CallNode)
        offese << "#{etichetta}:#{figlio.location.start_line}" if figlio.name == :name && !protetto
        protetto ||= escape_html?(figlio.name)
      end
      figlio.compact_child_nodes.each { |nipote| visita.call(nipote, protetto) }
    end
    nodo.arguments&.arguments&.each { |argomento| visita.call(argomento, false) }
    offese
  end

  let(:offese) do
    mio_file = Rails.root.join("spec/config/response_body_names_spec.rb")
    Rails.root.glob("spec/**/*_spec.rb").reject { |path| path == mio_file }.flat_map do |path|
      nomi_grezzi(path.read, path.relative_path_from(Rails.root).to_s)
    end
  end

  it "nessuna prova confronta l'HTML della pagina con un nome letto dal record" do
    expect(offese).to be_empty, <<~MSG
      Nome riletto dal record dentro un confronto su `response.body`:
      #{offese.join("\n")}

      Scrivi il testo che ti aspetti nella pagina invece di rileggerlo: fissa il nome quando crei il
      record (`create(:account, name: "Ada D'Angelo")`) e asserisci quella stessa stringa. Se il nome
      contiene un apostrofo o una e commerciale, avvolgila in `ERB::Util.html_escape`, che è la forma
      con cui la pagina la scrive davvero.
    MSG
  end

  # Un gate che non si prova è un gate di cui nessuno sa più cosa guardi: qui si dimostra su codice
  # finto che vede le forme vere e che non accusa quelle sane.
  it "riconosce le forme fragili e nient'altro" do
    fragili = <<~RUBY
      expect(response.body).to include(reader.name)
      expect(response.body).not_to include("\#{agent.name} ha cambiato lo stato")
      expect(response.body).to include(ticket.code, altro.name)
      expect(response.body).to include(uno.code).and include(due.name)
    RUBY
    sane = <<~RUBY
      expect(response.body).to include("Ada D'Angelo")
      expect(response.body).to include(ERB::Util.html_escape(altro.name))
      expect(Nokogiri::HTML(response.body).text).to include(owner.name)
      expect(response.body).to include(repo.full_name)
      expect(picker_options(response.body, "x")).to include(shared.name)
      expect(response.parsed_body["data"]).to include(account.name)
      create(:authorization_event, actor_name: member.name)
    RUBY

    expect(nomi_grezzi(fragili, "finto").size).to eq(4)
    expect(nomi_grezzi(sane, "finto")).to be_empty
  end
end
