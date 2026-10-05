# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-630 — su un ticket già concluso non si decide, da nessuna parte.
    #
    # La stessa decisione si poteva prendere da cinque posti diversi, e ognuno aveva la sua regola:
    # dalla prima pagina veniva rifiutata, dalla scheda del ticket passava. Il piano risultava
    # approvato, la domanda risposta, il blocco tolto. Finché il ticket restava chiuso non ripartiva
    # niente — ma il giorno in cui qualcuno lo riapriva, il lavoro ripartiva da uno stato che nessuno
    # aveva voluto. Stessa decisione, due risposte diverse: quella giusta dipendeva da dove avevi
    # premuto.
    #
    # La guardia scende QUI, dentro i service, e diventa l'unica: da lì nessuna pagina può aggirarla,
    # perché non c'è più una strada che non ci passi.
    #
    # LIMITE NOTO, dichiarato invece che nascosto: il controllo sta PRIMA della transazione, quindi
    # fra il controllo e la scrittura resta una finestra di microsecondi in cui una chiusura
    # concorrente passerebbe lo stesso. Chiuderla vuol dire rileggere lo stato sotto lock, e il lock
    # giusto è quello del TICKET, non della lavorazione: introdurlo qui cambierebbe l'ordine con cui
    # sei service prendono i lock, che è il modo classico di regalarsi un deadlock. Va fatto con
    # calma e con una prova di concorrenza vera, non in coda a questo cambiamento.
    #
    # Quello che la guardia copre è il caso per cui esiste: la pagina aperta da minuti in una scheda
    # del browser, dove il ticket è stato chiuso nel frattempo.
    module ConcludedTicketGate
      private

      # Il ticket sta su `@ticket`, o dietro la lavorazione, o dietro il chiarimento, a seconda del
      # service: si guarda dove c'è, invece di pretendere che tutti lo chiamino allo stesso modo.
      def concluded_ticket?
        concluded_gate_ticket&.status&.category_done?
      end

      def concluded_gate_ticket
        return @ticket if defined?(@ticket) && @ticket
        return @workflow&.ticket if defined?(@workflow)

        @clarification&.workflow&.ticket if defined?(@clarification)
      end

      def concluded_ticket
        Result.err(AppError.new(I18n.t("member.home.actions.ticket_concluded"),
                                code: "R409-WORKFLOW-013", status: :conflict))
      end
    end
  end
end
