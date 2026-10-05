# frozen_string_literal: true

module Usage
  # CYRA-733 — dal percorso di una pagina alla FUNZIONE che quella pagina serve.
  #
  # La telemetria d'uso (CYRA-700) registra `Controller#action`: 359 nomi di classe, giusti per un
  # inventario e inservibili per decidere cosa migliorare o togliere. La domanda di prodotto è
  # un'altra — quali funzioni vengono aperte — e ha già una risposta stabile: le chiavi del catalogo
  # dell'assistente (`Assistant::BuildCatalog::FUNCTIONS`), 31 nomi legati alla rotta reale.
  #
  # Riusare quel catalogo, invece di scriverne un secondo, evita l'unico difetto che conta qui: due
  # elenchi delle stesse funzioni che divergono, e una funzione rinominata da una parte sola che
  # risulta «mai usata» perché nessuno la registra più con quel nome.
  #
  # Il legame è il PERCORSO, non il controller: le pagine di una funzione stanno sotto lo stesso
  # inizio di percorso anche quando le serve un controller diverso (la tab dei documenti di un
  # progetto è `Member::ProjectDocumentsController` e resta la funzione «projects»). Il confronto è
  # per SEGMENTI, mai per prefisso di stringa.
  # Segments, never string prefixes: `/member/lists` must not catch a future `/member/listsx`.
  # Vince il percorso più lungo, così `/member/tickets/list` resta sotto «tickets» e non altrove.
  class FeatureMap
    class << self
      # Il percorso della richiesta senza gli identificativi: `/member/tickets/7f3c` → `/member/tickets/:id`.
      # I segmenti dinamici li dichiara la rotta (`request.path_parameters`), quindi non si indovina
      # cosa sia un id guardando la forma di un segmento. Serve anche come garanzia di riservatezza:
      # dal percorso normalizzato non passa nessun identificativo.
      def normalize(path, path_parameters = {})
        dynamic = path_parameters.to_h.symbolize_keys.except(:controller, :action, :format)

        dynamic.reduce(path.to_s) do |acc, (name, value)|
          raw = value.to_s
          next acc if raw.empty?

          acc.gsub(%r{(?<=/)#{Regexp.escape(raw)}(?=/|\z)}, ":#{name}")
        end
      end

      # La chiave della funzione a cui appartiene il percorso, o nil se il percorso non ne serve
      # nessuna del catalogo (le aree fuori dal catalogo restano coperte dal simbolo di rotta).
      def key_for(path)
        segments = path.to_s.split("/").reject(&:empty?)
        return nil if segments.empty?

        [ segments.size, max_depth ].min.downto(1) do |depth|
          key = index[segments.first(depth).join("/")]
          return key if key
        end
        nil
      end

      # Percorso della funzione (a segmenti) → chiave. Calcolato una volta: le rotte non cambiano
      # dentro un processo.
      def index
        @index ||= build_index
      end

      private

      def build_index
        routes = Rails.application.routes.url_helpers

        ::Assistant::BuildCatalog::FUNCTIONS.each_with_object({}) do |function, acc|
          prefix = routes.public_send(function[:helper]).to_s.split("/").reject(&:empty?).join("/")
          acc[prefix] ||= function[:key]
        end
      end

      def max_depth = @max_depth ||= index.keys.map { |prefix| prefix.count("/") + 1 }.max
    end
  end
end
