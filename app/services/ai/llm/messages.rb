# app/services/ai/llm/messages.rb
# frozen_string_literal: true

module Ai
  module Llm
    # Traduce il dialetto dei chiamanti nel wire OpenAI, in un posto solo (CYRA-765).
    #
    # I 14 service parlano ancora la forma ereditata da Gemini — `contents` con `role: user|model` e
    # `parts` (`text`, `inline_data`, `functionCall`, `functionResponse`). Cambiarli tutti insieme
    # al fornitore avrebbe toccato 14 service e 25 spec per un beneficio estetico; la conversione qui
    # tiene il cambio confinato, e il giorno in cui si vorrà un dialetto neutro sarà un refactor a sé.
    module Messages
      module_function

      def build(system:, contents:)
        [ { role: "system", content: system.to_s } ] + Array(contents).flat_map { |turn| convert(turn.deep_symbolize_keys) }
      end

      # Un turno può diventare PIÙ messaggi: una functionResponse per ogni chiamata, ciascuna nel suo
      # messaggio `tool`. Le functionCall del modello stanno invece in UN messaggio assistant.
      def convert(turn)
        parts = Array(turn[:parts])
        responses = parts.filter_map { |part| part[:functionResponse] }
        return responses.map { |response| tool_message(response) } if responses.any?

        calls = parts.filter_map { |part| part[:functionCall] }
        role = turn[:role].to_s == "model" ? "assistant" : "user"
        return { role: role, content: nil, tool_calls: calls.map { |call| tool_call(call) } } if calls.any?

        { role: role, content: content_of(parts) }
      end

      def tool_message(response)
        { role: "tool", tool_call_id: response[:id].to_s, content: response[:response].to_json }
      end

      def tool_call(call)
        { id: call[:id].to_s, type: "function",
          function: { name: call[:name].to_s, arguments: (call[:args] || {}).to_json } }
      end

      # Solo testo → stringa semplice (è ciò che il modello gestisce meglio e ciò che gli spec
      # confrontano); con immagini → lista di blocchi tipizzati.
      def content_of(parts)
        images = parts.filter_map { |part| part[:inline_data] }
        text = parts.filter_map { |part| part[:text] }.join
        return text if images.empty?

        blocks = text.empty? ? [] : [ { type: "text", text: text } ]
        blocks + images.map do |image|
          { type: "image_url", image_url: { url: "data:#{image[:mime_type]};base64,#{image[:data]}" } }
        end
      end
    end
  end
end
