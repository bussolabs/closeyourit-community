# frozen_string_literal: true

require "rails_helper"
require "json"
require "bundler/audit/configuration"

# CYRA-753 — Le segnalazioni di sicurezza messe da parte, e il perché di ognuna.
#
# Uno scanner che sbaglia si zittisce mettendo l'impronta dell'avviso in un elenco. Un elenco di
# impronte nude però non si rilegge: mesi dopo nessuno sa più se quella riga era davvero innocua o
# se qualcuno aveva fretta, e l'unico modo per scoprirlo è rifare da capo l'analisi che qualcuno
# aveva già fatto. La motivazione scritta accanto è ciò che rende la decisione rivedibile — ed è
# l'unica parte che nessuno strumento può ricostruire da sé.
#
# Due cose marciscono da sole: una voce senza nota e una voce che punta a codice che non esiste più.
# La seconda è già successa due volte in questo repository — il partial `home/_action_row` è stato
# cancellato con altro lavoro e la sua riga è rimasta a zittire un avviso che nessuno può più
# ricevere, e l'avviso sul link dei siti SEO è sparito quando la riga ha smesso di portare fuori
# dall'applicazione. Un elenco che cresce e non cala smette di essere un elenco di eccezioni e
# diventa una zona d'ombra.
#
# Chi le prende davvero è `bin/brakeman` nella CI (`scan_ruby`), grazie alle due opzioni nel
# binstub: rifare l'analisi qui costerebbe quaranta secondi a ogni giro della suite. Qui si presidia
# che quelle opzioni restino al loro posto — toglierle non rompe niente e nessuno se ne
# accorgerebbe — e si tiene la parte statica, che in locale risponde subito.
RSpec.describe "Le segnalazioni di sicurezza messe da parte (CYRA-753)" do
  describe "config/brakeman.ignore" do
    let(:ignored) do
      JSON.parse(Rails.root.join("config/brakeman.ignore").read).fetch("ignored_warnings")
    end

    # Il minimo perché una nota sia una spiegazione e non un'alzata di spalle. «Falso positivo» da
    # solo non dice niente a chi rilegge: la nota deve dire PERCHÉ l'input non può arrivare da fuori.
    LUNGHEZZA_MINIMA_MOTIVAZIONE_BRAKEMAN = 60

    it "spiega per esteso ogni avviso zittito" do
      senza_motivazione = ignored.reject { |warning| warning["note"].to_s.strip.length >= LUNGHEZZA_MINIMA_MOTIVAZIONE_BRAKEMAN }

      expect(senza_motivazione).to be_empty,
                                   "questi avvisi sono messi da parte senza dire perché: " \
                                   "#{senza_motivazione.map { |w| "#{w['file']}:#{w['line']}" }.join(', ')}"
    end

    it "non zittisce avvisi su file che non esistono più" do
      fantasmi = ignored.map { |warning| warning.fetch("file") }
                        .uniq
                        .reject { |file| Rails.root.join(file).exist? }

      expect(fantasmi).to be_empty,
                          "voci rimaste dopo la cancellazione del codice che le aveva generate: " \
                          "#{fantasmi.join(', ')}. Vanno tolte: zittiscono un avviso che nessuno " \
                          "può più ricevere."
    end
  end

  describe "bin/brakeman" do
    # Le opzioni si cercano fra quelle PASSATE, non nel file: il commento che le spiega le nomina
    # entrambe, e cercarle nel testo intero renderebbe verde un binstub a cui qualcuno le ha tolte
    # lasciando in piedi la spiegazione di ciò che non fa più.
    let(:opzioni) do
      Rails.root.join("bin/brakeman").read
           .lines
           .reject { |riga| riga.lstrip.start_with?("#") }
           .join[/ARGV\.unshift\((.*?)\)/m, 1].to_s
    end

    it "fallisce quando un avviso viene messo da parte senza nota" do
      expect(opzioni).to include("--ensure-ignore-notes")
    end

    it "fallisce quando resta in elenco una voce che non zittisce più niente" do
      expect(opzioni).to include("--ensure-no-obsolete-ignore-entries")
    end
  end

  describe "config/bundler-audit.yml" do
    let(:percorso) { Rails.root.join("config/bundler-audit.yml") }
    let(:righe) { percorso.read.lines.map(&:chomp) }
    let(:voci_ignorate) do
      righe.each_index.select { |i| righe[i].match?(/^\s*-\s*\S/) }
    end

    # La gemma legge il file con un parser suo e pretende che `ignore` sia una sequenza: scritta
    # come chiave nuda (`ignore:` e basta) solleva, e il controllo delle dipendenze morirebbe nella
    # CI per un errore di forma, non per una dipendenza vulnerabile.
    it "è una configurazione che bundler-audit sa leggere" do
      expect { Bundler::Audit::Configuration.load(percorso.to_s) }.not_to raise_error
    end

    it "non tiene segnaposto al posto di vulnerabilità vere" do
      identificativi = Bundler::Audit::Configuration.load(percorso.to_s).ignore.to_a
      inventati = identificativi.reject { |id| id.match?(/\A(CVE-\d{4}-\d+|GHSA-[0-9a-z]{4}(-[0-9a-z]{4}){2}|OSVDB-\d+)\z/) }

      expect(inventati).to be_empty,
                           "identificativi che non esistono in nessun archivio di vulnerabilità: " \
                           "#{inventati.join(', ')}"
    end

    it "spiega accanto a ogni vulnerabilità messa da parte perché non ci riguarda" do
      senza_motivazione = voci_ignorate.reject do |i|
        righe[0...i].reverse.take_while { |riga| riga.strip.start_with?("#") }.any? { |riga| riga.strip.length > 2 }
      end

      expect(senza_motivazione).to be_empty,
                                   "vulnerabilità messe da parte senza una riga di commento che " \
                                   "spieghi il perché (righe: #{senza_motivazione.map { |i| i + 1 }.join(', ')})"
    end
  end
end
