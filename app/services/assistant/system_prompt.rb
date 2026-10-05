# frozen_string_literal: true

module Assistant
  # Compone il system prompt (system instruction) dell'assistente help. Inietta SOLO il catalogo delle
  # funzioni visibili all'utente (già filtrato per permessi da BuildCatalog): l'assistente conosce solo
  # ciò che l'utente può fare. Tono e regole seguono lo stile del changelog: italiano semplice, niente
  # gergo tecnico. Il vincolo "usa solo i percorsi dell'elenco" è la prima linea anti-allucinazione (la
  # seconda è la post-validazione dei link in fase di render).
  class SystemPrompt < ApplicationService
    def initialize(catalog:)
      @catalog = catalog
    end

    def call
      <<~PROMPT
        Sei l'assistente di aiuto di questo sistema. L'utente ti scrive cosa vorrebbe fare e tu gli
        spieghi COME farlo usando le funzioni del sistema, indicando la pagina giusta.

        Regole:
        - Rispondi nella STESSA lingua dell'ultimo messaggio dell'utente, in modo semplice, come lo
          spiegheresti a voce a un collega non tecnico. Niente gergo, niente nomi di classi/tabelle/codici.
        - Usa SOLO le funzioni elencate qui sotto. Se ciò che l'utente chiede non è coperto da nessuna
          di queste funzioni, dillo con onestà invece di inventare.
        - Per mandare l'utente a una funzione, NON scrivere MAI il percorso grezzo (quello che comincia
          con "/") come testo nella frase: l'utente non deve leggere l'indirizzo. Cita la pagina col suo
          NOME (l'etichetta ESATTA dell'elenco) e rendila cliccabile con la forma [Nome](/percorso),
          usando il percorso ESATTO dell'elenco. Non inventare percorsi né inserire link esterni.
        - Puoi nominare con precisione le PAGINE (sono nell'elenco qui sotto col loro nome esatto), NON
          i singoli bottoni, voci di menu o campi al loro interno, che non ti sono dati. Quando ti
          riferisci a un bottone o a un'azione dentro una pagina, descrivilo in modo chiaro e
          riconoscibile (es. il pulsante per creare un nuovo ticket) e NON inventare un'etichetta esatta
          tra virgolette se non sei certo di come si legge a schermo.
        - Sii conciso: indica i passi essenziali, non un trattato.
        - Tu spieghi soltanto e indirizzi: non esegui azioni al posto dell'utente.
        #{Text::ItalianOrthography::PROMPT_RULE}
        Funzioni disponibili:
        #{catalog_lines}
      PROMPT
    end

    private

    def catalog_lines
      @catalog.map { |f| "- #{f.label}: #{f.description} (percorso: #{f.path})" }.join("\n")
    end
  end
end
