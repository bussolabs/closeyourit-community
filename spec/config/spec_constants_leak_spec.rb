# frozen_string_literal: true

require "rails_helper"
require "prism"

# Una costante scritta dentro un blocco `RSpec.describe` non appartiene a quel blocco: Ruby la
# assegna al livello lessicale del file, cioè a `Object`. Diventa globale, e due file di spec che
# scelgono lo stesso nome se la contendono — vince l'ultimo caricato.
#
# Non si vede quasi mai, e quando si vede sembra tutto tranne quello che è. Il caricamento è
# ordinato per file, gli shard della CI dividono i file in modo diverso a ogni cambio della suite, e
# finché i due file finiscono in shard diversi ognuno ha la sua copia e tutto è verde. Il giorno in
# cui atterrano insieme, uno dei due riceve il valore dell'altro: `spec/models/agents/
# workflow_ready_phase_loop_spec.rb` e `spec/services/agents/ticket_queues/prerequisites_spec.rb`
# dichiaravano tutti e due `FASI`, e il rosso arrivava come `TypeError: no implicit conversion of
# String into Integer` dentro `Array#fetch` — una riga che non nomina né l'altro file né la costante.
#
# Questa prova rende la collisione impossibile da introdurre di nuovo: non vieta le costanti negli
# spec (sono 39 file, e leggibili), vieta che due file ne dichiarino una con lo stesso nome.
RSpec.describe "le costanti dichiarate negli spec non si pestano fra loro" do
  # Solo le costanti che finiscono davvero su `Object`: quelle scritte dentro `module` o `class`
  # sono già annidate e non danno fastidio a nessuno.
  def costanti_globali(path)
    radice = Prism.parse_file(path.to_s).value
    trovate = []
    visita = lambda do |nodo, dentro_namespace|
      case nodo
      when Prism::ModuleNode, Prism::ClassNode, Prism::SingletonClassNode
        dentro_namespace = true
      when Prism::ConstantWriteNode
        trovate << nodo.name.to_s unless dentro_namespace
      end
      nodo.compact_child_nodes.each { |figlio| visita.call(figlio, dentro_namespace) }
    end
    visita.call(radice, false)
    trovate
  end

  it "nessun nome è dichiarato da due file diversi" do
    per_nome = Hash.new { |hash, chiave| hash[chiave] = [] }

    Dir.glob(Rails.root.join("spec/**/*.rb")).sort.each do |path|
      relativo = Pathname.new(path).relative_path_from(Rails.root).to_s
      costanti_globali(path).uniq.each { |nome| per_nome[nome] << relativo }
    end

    contese = per_nome.select { |_nome, files| files.uniq.size > 1 }
    dettaglio = contese.map { |nome, files| "#{nome}: #{files.uniq.join(', ')}" }.join("\n")

    expect(contese).to be_empty, <<~MESSAGGIO
      Queste costanti sono dichiarate da più di un file di spec e finiscono tutte su `Object`.
      Il file caricato per ultimo sovrascrive gli altri, e il rosso arriva altrove:

      #{dettaglio}

      Dai a ognuna un nome che nomini il suo file, oppure spostala dentro un modulo.
    MESSAGGIO
  end
end
