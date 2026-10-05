# frozen_string_literal: true

module Secrets
  # Diff cross-ambiente (drift) della matrice secrets di un progetto (CYRA-137, Fase 3 igiene Vault).
  # Un "buco" è una variabile LOCALE (Secrets::Variable) che ha valore in >= 1 ambiente ATTIVO del
  # progetto ed è assente in >= 1 altro ambiente attivo dello stesso progetto. I secret DELEGATI dallo
  # shared restano fuori dal diff per costruzione: non passano mai per `rows` (che viene da
  # @project.secret_variables, non da @delegated_secrets) — gestiti a livello org.
  # Nessuna query: lavora sui dati GIA' caricati dalla matrice del controller.
  class Drift
    # rows: stessa forma di @rows di Member::ProjectSecretsController#load_matrix — array di coppie
    # [name, { environment_id => Secrets::Variable }].
    # environments: gli ambienti ATTIVI/dichiarati del progetto (@environments del controller); si usa
    # solo il loro `id`, così una cella su un ambiente non incluso qui (non attivo/non dichiarato) è
    # ignorata — non esiste per la matrice, quindi non conta né come presenza né come buco.
    def initialize(rows:, environments:)
      @rows = rows
      @environment_ids = environments.map(&:id)
    end

    # true se la cella [nome, ambiente] è un buco: il nome ha valore su almeno un altro ambiente attivo
    # ma non su questo.
    def hole?(name, environment_id)
      holes_by_name.fetch(name, []).include?(environment_id)
    end

    # Numero di variabili (nomi) che hanno almeno un buco.
    def affected_names_count
      holes_by_name.size
    end

    # { name => [environment_id mancanti] } per ogni variabile a presenza mista — i buchi UNO PER UNO,
    # non solo il conteggio. Serve a Secrets::HealthCheck (CYRA-409) per dire QUALE variabile manca e
    # in QUALE ambiente, invece del solo totale. Vuoto = nessun buco.
    def holes
      holes_by_name
    end

    # Numero totale di celle-buco nella matrice (somma dei buchi su tutte le variabili).
    def holes_count
      holes_by_name.values.sum(&:size)
    end

    def any?
      holes_count.positive?
    end

    private

    # { name => [environment_id mancanti] } — solo per i nomi a presenza MISTA (>= 1 presente E >= 1
    # assente tra gli ambienti attivi). Una variabile completa ovunque o assente ovunque non compare:
    # non è un buco, è uno stato uniforme.
    def holes_by_name
      @holes_by_name ||= @rows.each_with_object({}) do |(name, by_env), acc|
        present_ids = @environment_ids.select { |id| by_env[id] }
        next if present_ids.empty? || present_ids.size == @environment_ids.size

        acc[name] = @environment_ids - present_ids
      end
    end
  end
end
