# frozen_string_literal: true

module Assistant
  module Tools
    # Base di un attrezzo dell'assistente: una funzione che il modello può chiedere di eseguire.
    #
    # Ogni attrezzo dichiara sé stesso (`declaration`, nel formato `functionDeclarations` che il
    # client traduce nel wire del server AI) e
    # sa eseguirsi su un Context congelato. Il valore di ritorno è un Hash che finisce nel prompt del
    # giro successivo: va tenuto PICCOLO e già masticato — ogni campo inutile è contesto che il
    # modello deve leggere e che paghiamo a token.
    #
    # Un attrezzo non solleva mai per un dato mancante: risponde `{ error: "..." }` in modo che il
    # modello possa dirlo a chi ha chiesto, invece di far fallire l'intera conversazione.
    class Base
      # Tetto sugli elenchi restituiti al modello: oltre non serve a rispondere e costa soltanto.
      MAX_ROWS = 20

      def self.declaration = raise(NotImplementedError)
      def self.tool_name = declaration.fetch(:name)

      def initialize(context:)
        @context = context
      end

      def call(_args) = raise(NotImplementedError)

      private

      attr_reader :context

      def not_visible(reference)
        { error: "Nessun progetto visibile corrisponde a #{reference.presence || '(vuoto)'}." }
      end
    end
  end
end
