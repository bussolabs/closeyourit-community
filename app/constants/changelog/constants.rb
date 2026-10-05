# frozen_string_literal: true

module Changelog
  # Costanti della lettura del CHANGELOG.md dentro l'app (rules/constants.md): quante release si
  # mostrano nel modale della sidebar e quante nella pagina dello storico.
  module Constants
    # Numero di release mostrate nel modale changelog della sidebar (le altre nella pagina storico).
    MODAL_RELEASES = 5

    # Quante versioni per pagina nello storico completo (CYRA-445). Le voci sono paragrafi interi:
    # con 300+ versioni rese in un colpo la pagina era una colonna unica da scorrere per minuti.
    PER_PAGE = 10
  end
end
