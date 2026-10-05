# frozen_string_literal: true

require "rails_helper"

# CYRA-798 — i commenti di questi file raccontavano cosa andava storto mesi fa e perché si è
# cambiato. Chi li apriva oggi doveva ricostruire tutta la storia per arrivare alla regola, che
# spesso era l'ultima riga di venti. Qui si guarda il SORGENTE: il commento dice la regola e cita il
# ticket, il racconto sta nel ticket.
#
# La regola per esteso è in docs/regole-commenti.md.
RSpec.describe "I commenti dicono la regola, non la storia", type: :model do
  # Il tetto per blocco di commento consecutivo. La regola sta in una o due righe; quattro lasciano
  # margine a una regola con la sua eccezione, o a un elenco corto, senza fare spazio al racconto.
  TETTO_RIGHE = 4

  # I file potati, con i ticket che i loro commenti citavano PRIMA della potatura. Presidiano le due
  # metà della Definition of Done: nessun commento torna a raccontare, e nessun riferimento si perde
  # per strada — accorciare un commento non deve costare il filo verso la storia completa.
  #
  # Il confronto è per INCLUSIONE, non per uguaglianza: un ticket nuovo si cita senza toccare questo
  # elenco, uno vecchio non si può togliere. Un file nuovo si aggiunge qui il giorno in cui lo si
  # pota, ed è così che il perimetro cresce.
  PRESIDIATI = {
    "app/models/agents/workflow.rb" => %w[
      CYAU-79 CYAU-82 CYAU-83 CYRA-212 CYRA-218 CYRA-267 CYRA-280 CYRA-317 CYRA-504 CYRA-598
      CYRA-601 CYRA-604 CYRA-609 CYRA-613 CYRA-617 CYRA-618 CYRA-620 CYRA-624 CYRA-629 CYRA-664
      CYRA-673 CYRA-675 CYRA-689 CYRA-796
    ],
    "app/services/home/approvals/queue.rb" => %w[
      CYRA-219 CYRA-262 CYRA-284 CYRA-290 CYRA-316 CYRA-317 CYRA-319 CYRA-374 CYRA-448 CYRA-593
      CYRA-598 CYRA-610 CYRA-630 CYRA-665 CYRA-689 CYRA-796
    ],
    "app/controllers/member/monitoring/error_groups_controller.rb" => %w[
      CYRA-45 CYRA-46 CYRA-49 CYRA-51 CYRA-60 CYRA-153 CYRA-163 CYRA-192 CYRA-340 CYRA-375
      CYRA-376 CYRA-381 CYRA-383 CYRA-400 CYRA-562 CYRA-694 CYRA-728 CYRA-737 CYRA-822
    ],
    "app/models/ticketing/ticket.rb" => %w[
      CYRA-76 CYRA-80 CYRA-163 CYRA-168 CYRA-184 CYRA-220 CYRA-223 CYRA-374 CYRA-389 CYRA-392
      CYRA-620 CYRA-622 CYRA-746 CYRA-770 CYRA-779
    ],
    "app/services/agents/workflows/phase_resolver.rb" => %w[
      CYRA-280 CYRA-317 CYRA-504 CYRA-592 CYRA-598 CYRA-602 CYRA-612 CYRA-615 CYRA-619 CYRA-620
      CYRA-624 CYRA-629 CYRA-631 CYRA-796
    ]
  }.freeze

  # CYRA-800 — un file potato può DIVIDERSI, e i suoi riferimenti si spostano nei pezzi nati da lui.
  # Il filo verso la storia non si perde: cambia solo dove passa. I pezzi nascono presidiati come il
  # padre — il tetto di quattro righe vale anche per loro.
  NATI_DALLA_DIVISIONE = {
    "app/controllers/member/monitoring/error_groups_controller.rb" => %w[
      app/controllers/member/monitoring/error_groups/triages_controller.rb
      app/controllers/member/monitoring/error_groups/merges_controller.rb
      app/controllers/concerns/member/monitoring/error_group_scoping.rb
    ]
  }.freeze

  # Righe di solo commento, raggruppate per blocchi contigui: è l'unità che si legge tutta d'un
  # fiato, e quindi l'unità da misurare. Un commento in coda a una riga di codice non fa blocco.
  def blocchi_di_commento(file)
    righe = Rails.root.join(file).readlines(chomp: true)
    righe.each_with_index.chunk_while { |(prima, _), (dopo, _)|
      prima.strip.start_with?("#") && dopo.strip.start_with?("#")
    }.filter_map { |gruppo|
      next unless gruppo.first.first.strip.start_with?("#")

      { riga: gruppo.first.last + 1, righe: gruppo.size }
    }
  end

  # I ticket citati dai commenti di un file: uno per riga di commento, senza ripetizioni.
  def ticket_citati_in(file)
    Rails.root.join(file).readlines(chomp: true)
         .select { |riga| riga.strip.start_with?("#") }
         .flat_map { |riga| riga.scan(/\b(?:CY[A-Z]{2,4})-\d+\b/) }
         .uniq
  end

  (PRESIDIATI.keys + NATI_DALLA_DIVISIONE.values.flatten).uniq.each do |file|
    describe file do
      it "non ha commenti più lunghi di #{TETTO_RIGHE} righe" do
        lunghi = blocchi_di_commento(file).select { |blocco| blocco[:righe] > TETTO_RIGHE }
                                          .map { |blocco| "riga #{blocco[:riga]} (#{blocco[:righe]} righe)" }

        expect(lunghi).to be_empty,
                          "#{file} racconta invece di dire la regola: #{lunghi.join(', ')}. " \
                          "Tieni la regola e il ticket, sposta il racconto nel ticket."
      end

      next unless PRESIDIATI.key?(file)

      it "cita ancora tutti i ticket che citava" do
        # I pezzi nati dalla divisione valgono come il padre: il riferimento è ancora raggiungibile,
        # solo da un altro file. Fuori da una divisione l'insieme è il solo file, come prima.
        citati = ([ file ] + NATI_DALLA_DIVISIONE.fetch(file, [])).flat_map { |f| ticket_citati_in(f) }.uniq

        expect(citati).to include(*PRESIDIATI.fetch(file)),
                          "#{file} ha perso dei riferimenti: #{(PRESIDIATI.fetch(file) - citati).join(', ')}. " \
                          "Accorciare un commento non toglie il filo verso la storia completa."
      end
    end
  end
end
