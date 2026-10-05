# frozen_string_literal: true

# CYRA-770 — Il parere dell'AI e la decisione di una persona smettono di condividere la stessa
# colonna. Prima l'AI scriveva direttamente `agent_eligibility`, cioè il campo che la coda degli
# agenti interroga: un verdetto del modello bastava a mandare un ticket in lavorazione autonoma.
# Ora l'AI scrive solo `agent_eligibility_advice`, che nessuna coda legge; `agent_eligibility` resta
# la decisione, e la muove soltanto una persona.
#
# `advice` nasce a 0 (`unknown`) e vale come «l'AI non si è ancora espressa»: è distinto dal
# `pending` della decisione, perché sono due assi diversi — un ticket può avere un parere favorevole
# e nessuna decisione, ed è esattamente lo stato in cui questa migration lascia il parco esistente.
class SplitAgentEligibilityAdviceFromDecision < ActiveRecord::Migration[8.1]
  def up
    add_column :ticketing_tickets, :agent_eligibility_advice, :integer, null: false, default: 0
    # text come `agent_eligibility_reason`: sono 1-3 frasi del modello, varchar(255) troncherebbe.
    add_column :ticketing_tickets, :agent_eligibility_advice_reason, :text

    sposta_marchi_automatici_nel_parere
    riattribuisci_azzeramenti_storici
  end

  # Gli azzeramenti passati sono stati registrati come «valutazione automatica», perché fino a ieri
  # ogni sorgente diversa da `human` finiva lì. Sono gesti di una persona, e lasciarli attribuiti al
  # modello significa che chi legge la cronologia vede il robot al posto di chi ha premuto.
  # Si riconoscono senza ambiguità: solo l'azzeramento porta un ticket a `pending`, il parere dell'AI
  # dice sempre `allowed` o `blocked`. Gli eventi senza attore restano dove sono: non avendo un
  # responsabile da mostrare, spostarli non aggiungerebbe niente e toglierebbe l'icona giusta.
  def riattribuisci_azzeramenti_storici
    execute(<<~SQL.squish)
      UPDATE ticketing_events
         SET action = 'agent_eligibility_overridden'
       WHERE action = 'agent_eligibility_evaluated'
         AND actor_id IS NOT NULL
         AND data #>> '{agent_eligibility,to}' = 'pending'
    SQL
  end

  # I marchi automatici esistenti sono pareri, non decisioni: si spostano nelle colonne del parere e
  # il ticket torna in attesa di una persona. Fail-closed voluto — un ticket che ieri era in coda
  # perché l'AI lo aveva marcato `allowed` oggi ne esce, ed è il senso di tutto il ticket.
  # Metodo a sé e non un `execute` in linea dentro `up`: così lo spec può provarlo su un database
  # dove le colonne ci sono già, senza rieseguire gli `add_column`.
  def sposta_marchi_automatici_nel_parere
    execute(<<~SQL.squish)
      UPDATE ticketing_tickets
         SET agent_eligibility_advice = agent_eligibility,
             agent_eligibility_advice_reason = agent_eligibility_reason,
             agent_eligibility = 0,
             agent_eligibility_reason = NULL
       WHERE agent_eligibility_source = 0
    SQL
    # Le righe con `agent_eligibility_source = 1` (human) non si toccano: sono decisioni prese da una
    # persona, ed è la sola cosa che questo ticket riconosce come decisione.
  end

  # Il `down` toglie le colonne e basta: non ricostruisce. Riportare il parere dentro la decisione
  # rimetterebbe in coda ticket che nessuno ha mai consentito — cioè rifarebbe di proposito il guasto
  # che questa migration esiste per chiudere. Chi torna indietro riparte da tutti i ticket in attesa.
  def down
    remove_column :ticketing_tickets, :agent_eligibility_advice
    remove_column :ticketing_tickets, :agent_eligibility_advice_reason
  end
end
