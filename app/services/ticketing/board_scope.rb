# frozen_string_literal: true

module Ticketing
  # CYRA-739 — the board columns in one place: one column per status, a first block of cards, the
  # «show more» footer, and the recent window on DONE statuses, shared by the page and its footer.
  #
  # Il TOTALE della colonna non si calcola qui: arriva dai conteggi aggregati del chiamante e resta
  # il numero vero anche quando le card mostrate sono un blocco o una finestra recente.
  class BoardScope
    # Una colonna pronta per la view (CYRA-390): lo stato, le card del blocco, se offrire «mostra
    # altre», e il totale reale dello stato.
    Column = Data.define(:status, :tickets, :has_more, :total)

    # Un blocco di card di UNA colonna: quelle da rendere e se ce ne sono altre dopo.
    Block = Data.define(:tickets, :has_more)

    class << self
      # Le colonne della pagina: primo blocco per ciascuno stato attivo.
      def columns(scope:, statuses:, counts:, searching: false)
        statuses.map do |status|
          batch = cards(scope: scope, status: status, searching: searching)
          Column.new(status: status, tickets: batch.tickets, has_more: batch.has_more,
                     total: counts[status.id].to_i)
        end
      end

      # Un blocco di card (CYRA-390/CYRA-572): ne chiede una in più del blocco per sapere se offrire
      # «mostra altre», senza una seconda query di conteggio. La pagina 1 è il blocco già reso dalla
      # pagina, quindi il piede chiede dalla 2 in poi.
      def cards(scope:, status:, page: 1, searching: false)
        per = Constants::BOARD_COLUMN_PAGE
        records = for_column(scope, status, searching)
                  .offset((page - 1) * per).limit(per + 1).to_a
        Block.new(tickets: records.first(per), has_more: records.size > per)
      end

      private

      # Card di UNA colonna a partire dallo scope già filtrato/cercato. Le colonne CONCLUSE (status
      # category `done`) sono ristrette alla finestra recente per `closed_at` e ordinate per
      # conclusione discendente (le più fresche in cima): una colonna conclusa risponde a «cos'è
      # uscito ultimamente». Le altre per creazione discendente.
      #
      # `reorder` esplicito: la ricerca semantica lascia un ORDER BY di pertinenza che qui — dove le
      # card sono già raggruppate per colonna — non serve e romperebbe il "periodo recente"; il suo
      # filtro (WHERE sugli id) sopravvive al reorder, quindi la ricerca continua a restringere le
      # card. Componibile con .limit/.offset del chiamante.
      # A search drops the recent window: a match closed long ago must still show up as a card.
      def for_column(scope, status, searching)
        column = scope.where(status_id: status.id)
        if status.category_done?
          column = column.where(closed_at: Constants::BOARD_DONE_WINDOW.ago..) unless searching
          return column.reorder(closed_at: :desc)
        end

        column.reorder(created_at: :desc)
      end
    end
  end
end
