# frozen_string_literal: true

require "rails_helper"

# CYRA-742 — i file di supporto delle view erano diventati il posto in cui finiva tutto quello che una
# pagina deve sapere: i grafici dei server, gli stati delle unit di sistema, i formati delle durate e i
# valori oscurati, seicentocinquanta righe in un file solo. Chi doveva cambiare il colore di una barra
# apriva lo stesso file di chi doveva cambiare il testo di uno stato.
#
# Qui si guarda il SORGENTE, non il comportamento: che ogni file abbia una misura leggibile, che le
# parti esistano davvero e che nessun nome chiamato dalle pagine sia sparito per strada. Le prove di
# comportamento restano quelle degli helper (spec/helpers/**) e delle richieste, che sono la rete vera
# di questa divisione.
RSpec.describe "I file di supporto delle view non fanno tutto", type: :model do
  # Il tetto della Definition of Done. Non è un numero estetico: sopra questa misura un file smette di
  # avere UN compito e torna a essere il cassetto di tutto, che è esattamente il problema.
  let(:tetto_righe) { 150 }

  it "nessun file di supporto supera le centocinquanta righe" do
    sopra = Dir[Rails.root.join("app/helpers/**/*.rb")].sort.filter_map { |file|
      misura = Pathname(file).readlines.size
      "#{Pathname(file).relative_path_from(Rails.root)} (#{misura})" if misura > tetto_righe
    }

    expect(sopra).to be_empty,
                     "Questi file di supporto superano le #{tetto_righe} righe: #{sopra.join(', ')}. " \
                     "Quello che è cresciuto va nella parte che ha quel compito."
  end

  # Le parti nominate dal ticket, ciascuna col proprio compito: chi cambia un grafico apre i grafici,
  # chi cambia uno stato apre gli stati, chi cambia un formato apre i formati.
  {
    "i grafici e gli assi dei server" => %w[Servers::ChartsHelper Servers::AxesHelper],
    "lo stato di una macchina e delle sue unit" => %w[Servers::StatusHelper Servers::SystemdHelper],
    "i grafici condivisi da errori e metriche" => %w[Monitoring::ChartsHelper],
    "i valori oscurati dagli scrubber" => %w[Monitoring::ScrubbingHelper],
    "le durate e i confronti degli agenti" => %w[Agents::DurationsHelper]
  }.each do |compito, moduli|
    it "la parte che ha in carico #{compito} esiste ed è caricabile" do
      assenti = moduli.reject { |nome| Object.const_defined?(nome) }

      expect(assenti).to be_empty, "Queste parti non esistono: #{assenti.join(', ')}."
    end
  end

  # Le grafie che dicono «la regola è tornata nel file che le raccoglie». Ognuna è il cuore di una
  # parte estratta: ritrovarla nell'aggregatore significa che ne esistono di nuovo due copie.
  {
    "app/helpers/servers_helper.rb" => [ "def server_", "SYSTEMD_", "PCT_CRIT =" ],
    "app/helpers/monitoring_helper.rb" => [ "def error_", "def chart_", "SCRUBBED_" ],
    "app/helpers/metrics_helper.rb" => [ "def metric_", "def occurrence_", "def perf_" ],
    "app/helpers/agents_helper.rb" => [ "def agent_", "def compare_row" ]
  }.each do |file, grafie|
    it "#{file} raccoglie le parti e non riscrive le regole" do
      codice = Rails.root.join(file).readlines.reject { |riga| riga.strip.start_with?("#") }
      tornate = grafie.select { |grafia| codice.any? { |riga| riga.include?(grafia) } }

      expect(tornate).to be_empty,
                         "Queste grafie sono tornate nel file che raccoglie le parti: #{tornate.join(', ')}. " \
                         "Vivono nella parte che ha quel compito, non qui."
    end
  end

  # La rete che rende innocua la divisione: una pagina chiama i metodi per nome, e un nome rimasto
  # fuori da ogni parte non si vede finché qualcuno non apre quella pagina. Qui si legge dalle pagine
  # stesse quali nomi servono e si controlla che il contesto delle view risponda a tutti.
  # Le chiamate precedute da un punto sono metodi di un altro oggetto (`Realtime::Streams.error_group`),
  # non del contesto delle view: restano fuori.
  let(:prefissi_dominio) { %w[server_ error_ metric_ agent_ uptime_ website_ chart_ log_ occurrence_ perf_] }

  it "ogni nome chiamato dalle pagine esiste ancora nel contesto delle view" do
    regex = /(?<![.\w])((?:#{prefissi_dominio.join('|')})[a-z0-9_]*[?!]?)\s*\(/
    chiamate = Dir[Rails.root.join("app/views/**/*.erb"), Rails.root.join("app/components/**/*.erb")]
      .flat_map { |file| File.read(file).scan(regex).flatten }.uniq.sort
    vista = ApplicationController.helpers
    mancanti = chiamate.reject { |nome| vista.respond_to?(nome) }

    expect(chiamate.size).to be > 100, "La scansione non ha trovato le chiamate delle pagine: controlla la regola."
    expect(mancanti).to be_empty,
                        "Queste pagine chiamano nomi che nessuna parte definisce più: #{mancanti.join(', ')}."
  end

  # La trappola della divisione, vista dal vivo: una parte messa dentro un namespace OSCURA per tutto
  # quel namespace il nome di primo livello uguale al suo. `app/helpers/member/navigation/` definiva
  # `Member::Navigation`, e da quel momento OGNI controller dell'area che scriveva `Navigation::Group`
  # — il registro dei nodi della sidebar, citato per nome nudo — moriva con «uninitialized constant
  # Member::Navigation::Group». Le pagine di panoramica sono cadute tutte insieme.
  #
  # La regola che ne esce è semplice e si controlla sul nome: una parte annidata non può chiamarsi
  # come qualcosa che esiste già al primo livello. Vale per il modulo e per ogni cartella che lo
  # contiene.
  it "nessuna parte annidata porta un nome che esiste già al primo livello" do
    radice = Rails.root.join("app/helpers")
    collisioni = Dir[radice.join("**/*.rb")].sort.flat_map { |file|
      pezzi = Pathname(file).relative_path_from(radice).to_s.delete_suffix(".rb").split("/")
      # Il primo pezzo È di primo livello: collide con se stesso per definizione.
      pezzi.drop(1).filter_map { |pezzo|
        nome = pezzo.camelize
        "#{pezzi.join('/')}.rb → #{nome}" if Object.const_defined?(nome, false)
      }
    }

    expect(collisioni).to be_empty,
                          "Queste parti oscurano un nome di primo livello: #{collisioni.join(', ')}. " \
                          "Dentro quel namespace il nome nudo smette di risolvere dove risolveva prima."
  end

  # Le costanti citate per nome fuori dagli helper (`ServersHelper::PCT_WARN` negli spec, il tetto del
  # titolo di un registro nelle richieste): la divisione non deve spostarle da sotto il nome con cui
  # sono già chiamate altrove.
  it "le costanti citate per nome restano raggiungibili dall'aggregatore" do
    expect(ServersHelper::PCT_WARN).to eq(50)
    expect(ServersHelper::PCT_CRIT).to eq(80)
    expect(MonitoringHelper::LOG_HEADLINE_MAX).to eq(120)
  end
end
