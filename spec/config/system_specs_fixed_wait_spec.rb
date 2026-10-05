# frozen_string_literal: true

require "rails_helper"
require "prism"

# CYRA-732 — nelle prove che guidano un browser vero non si aspetta un TEMPO, si aspetta una
# CONDIZIONE. Un `sleep` nudo è una scommessa sulla velocità della macchina: su un portatile carico
# o su uno shard di CI che ospita più processi la finestra scade prima che la pagina reagisca e la
# prova diventa rossa senza che nulla si sia rotto; su una macchina scarica quel tempo è tutto
# sprecato, moltiplicato per ogni esempio che lo contiene.
#
# Il guasto che ne nasce è il peggiore da diagnosticare: è intermittente, cambia con l'ordine degli
# esempi e non si riproduce dove lo si guarda. Questo gate ferma il primo `sleep` che rientra.
#
# Il polling vive in UN posto solo, `spec/support/system_wait_helpers.rb`: lì il tempo è il passo fra
# due controlli della condizione (con una scadenza), non l'attesa cieca prima di guardare.
RSpec.describe "attese nelle prove di sistema" do
  # Si legge l'ALBERO del file, non il suo testo. Una regex su `sleep` è sempre sbagliata da un lato
  # dei due: stretta abbastanza da non accusare la parola scritta dentro una frase (`pg_sleep`,
  # «container in idle-sleep») lascia passare le forme vere che non le somigliano — `Kernel.sleep(1)`
  # ha un punto davanti, `sleep ATTESA` non ha cifre dietro, `sleep(\n 1.5\n)` sta su tre righe.
  # Per il parser, invece, una chiamata è una chiamata e una stringa è una stringa: nessuna delle due
  # ambiguità esiste.
  def attese_a_tempo(sorgente, etichetta)
    risultato = Prism.parse(sorgente)
    return [ "#{etichetta} — sorgente non analizzabile: #{risultato.errors.first&.message}" ] if risultato.failure?

    trovate = []
    visita = lambda do |nodo|
      trovate << "#{etichetta}:#{nodo.location.start_line}" if nodo.is_a?(Prism::CallNode) && nodo.name == :sleep
      nodo.compact_child_nodes.each { |figlio| visita.call(figlio) }
    end
    visita.call(risultato.value)
    trovate
  end

  let(:offese) do
    Rails.root.glob("spec/system/**/*.rb").flat_map do |path|
      attese_a_tempo(path.read, path.relative_path_from(Rails.root).to_s)
    end
  end

  it "nessuna prova nel browser aspetta un tempo fisso" do
    expect(offese).to be_empty, <<~MSG
      Attesa a tempo in una prova di sistema:
      #{offese.join("\n")}

      Aspetta la condizione, non il tempo: `have_css`/`have_text`/`have_current_path` quando la
      condizione è nella pagina, `wait_until { ... }` (spec/support/system_wait_helpers.rb) quando è
      lato server o dentro il browser.
    MSG
  end

  # Un gate che non si prova è un gate che nessuno sa se guarda ancora nel posto giusto: qui si
  # dimostra su codice finto che vede le forme vere — comprese le tre che una regex si perde — e che
  # non accusa ciò che con `sleep` condivide solo le lettere.
  it "riconosce ogni forma dell'attesa a tempo e nient'altro" do
    vere = <<~RUBY
      sleep 1.5
      sleep(0.05)
      Kernel.sleep(1)
      sleep ATTESA_MASSIMA
      sleep(
        1.5
      )
    RUBY
    finte = <<~RUBY
      ActiveRecord::Base.connection.execute("SELECT pg_sleep(1.1)")
      it("esclude i container gestiti da un idle-sleep manager") { expect(page).to have_text("sleep") }
    RUBY

    expect(attese_a_tempo(vere, "vere").size).to eq(5)
    expect(attese_a_tempo(finte, "finte")).to be_empty
  end

  it "il polling condiviso esiste e concede la stessa finestra del resto di Capybara" do
    helper = Rails.root.join("spec/support/system_wait_helpers.rb")

    expect(helper).to exist
    expect(helper.read).to include("Capybara.default_max_wait_time")
  end
end
