# frozen_string_literal: true

module Ideas
  # Costanti del dominio idee (rules/constants.md).
  module Constants
    # Tetto di un commento a un'idea (CYRA-371). NON è Ticketing::Constants::COMMENT_MAX_CHARS, e la
    # divergenza è il punto: su un ticket il commento è breve per costruzione perché il testo lungo
    # ha un posto suo, il resoconto di lavorazione (Ticketing::Constants::REPORT_MAX_CHARS). Su
    # un'idea quel posto non esiste — il commento È il luogo dove si argomenta una decisione di
    # prodotto, e 240 caratteri sono lo spazio di un tweet: il vincolo non proteggeva niente e
    # spostava la discussione su altri canali, dove non torna più accanto all'idea.
    #
    # Il valore sta fra la descrizione di un ticket (4.000) e il resoconto (20.000): un intervento
    # discorsivo ci sta comodo, un diff incollato no.
    COMMENT_MAX_CHARS = 5_000

    # Oltre questa misura il commento è reso RITAGLIATO nella discussione, con il comando «mostra
    # tutto» (Stimulus ui--clamp, come l'analisi tecnica di un ticket). Non tocca il dato: è la
    # contropartita del tetto largo — senza, un solo intervento lungo occuperebbe la pagina e gli
    # altri sparirebbero sotto. Sotto la soglia nessun comando: un «mostra tutto» su tre righe è
    # rumore. Circa il doppio di un commento breve: un intervento di poche righe si legge intero.
    COMMENT_CLAMP_CHARS = 600
  end
end
