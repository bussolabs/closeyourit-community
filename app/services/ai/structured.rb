# frozen_string_literal: true

module Ai
  # Punto unico da cui passano le chiamate che vogliono un JSON conforme a uno schema.
  #
  # PERCHÉ ESISTE (CYRA-594): al gateway Proxanything lo stesso risultato si chiedeva travestendolo
  # da function call (`tool_choice: "required"`) — il modello non usava nessun attrezzo, restituiva
  # solo gli argomenti, e chi chiamava doveva spacchettarli da `choices[0].message`. Il client
  # vincola l'output nativamente con `response_schema`, quindi il travestimento sparisce e resta la
  # sola cosa che serviva davvero: schema dentro, Hash fuori.
  #
  # LE IMMAGINI PASSANO DI QUI perché il formato cambia: OpenAI voleva `image_url` con una data URL
  # (`data:image/png;base64,…`), qui si passa `inline_data` con mime type e base64 in campi separati:
  # è Ai::Llm::Messages a ricomporre la data URL per il wire OpenAI.
  # Tradurlo dentro ogni service significherebbe scriverlo bene sei volte — e sbagliarlo non solleva
  # niente: una parte immagine che il client non riconosce viene ignorata, il modello risponde lo
  # stesso sul solo testo, e nessuno si accorge che la foto non l'ha mai vista.
  module Structured
    module_function

    # images: [{ mime_type:, data: <base64> }]. `max_output_tokens` e `model` restano opzionali:
    # omessi valgono i default del client (modello strutturato, tetto strutturato), che è ciò che
    # serve a un'estrazione. Li passa chi genera prosa che leggerà un umano.
    # `deadline_seconds` è il tetto totale della chiamata (CYRA-766): il client legge in streaming, e
    # il read timeout limita l'attesa fra un pezzo e l'altro, non quanto dura tutto insieme. Si passa
    # solo dove qualcuno sta aspettando davanti a uno schermo.
    def call(client:, system:, user:, schema:, images: [], max_output_tokens: nil, model: nil, deadline_seconds: nil)
      options = { system: system, contents: contents(user, images), response_schema: schema }
      options[:max_output_tokens] = max_output_tokens if max_output_tokens
      options[:model] = model if model
      options[:deadline_seconds] = deadline_seconds if deadline_seconds

      client.generate_content(**options)
    end

    # Un turno solo, di ruolo utente: il contesto di sistema viaggia già per conto suo in `system`.
    def contents(user, images)
      parts = [ { text: user.to_s } ]
      parts += Array(images).map do |image|
        { inline_data: { mime_type: image.fetch(:mime_type), data: image.fetch(:data) } }
      end

      [ { role: "user", parts: parts } ]
    end
  end
end
