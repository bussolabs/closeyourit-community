# frozen_string_literal: true

# Rendering del corpo di un messaggio dell'assistente. Il testo del modello è SEMPRE escapato (mai HTML
# grezzo dall'LLM). I percorsi interni /member/... diventano link cliccabili SOLO se corrispondono a una
# rotta reale (seconda difesa anti-allucinazione, oltre al vincolo nel system prompt): un percorso
# inventato resta testo, non un link rotto. Supporta sia la forma markdown `[testo](/percorso)` sia il
# percorso scritto per esteso.
#
# Da CYRA-261 il corpo passa dal markdown vero (MarkdownHelper): il modello risponde per elenchi e
# grassetti, che prima si leggevano coi trattini e gli asterischi in chiaro. Il filtro sui link resta
# intero e vale ora su OGNI anchor prodotto dal markdown: né un `[clicca](https://esca.example)`
# allucinato né uno iniettato in un contenuto letto dal modello arriva cliccabile — diventa testo.
module AssistantHelper
  # Percorso interno "nudo" dentro la frase (la forma markdown `[testo](/percorso)` la risolve già il
  # renderer, e finisce nel filtro sugli anchor).
  ASSISTANT_PATH = %r{/member/[\w/-]+}
  LINK_CLASS = "font-semibold text-indigo-600 dark:text-indigo-400 underline decoration-indigo-200 dark:decoration-indigo-500/60 underline-offset-2 hover:decoration-indigo-500 dark:hover:decoration-indigo-400"

  def assistant_message_html(message)
    return assistant_voice_html(message) if message.role_user? && (message.status_transcribing? || message.status_failed?)
    return assistant_failed_html(message) if message.status_failed?

    fragment = Nokogiri::HTML5.fragment(render_markdown(message.content, remote_images: false))
    fragment.css("a").each { |anchor| assistant_filter_anchor(anchor) }
    # I percorsi nudi il markdown non li tocca: li aggancia qui, saltando ciò che è già un link e il
    # codice (dentro un blocco di codice un percorso è un esempio da leggere, non un bottone da premere).
    fragment.xpath(".//text()[not(ancestor::a) and not(ancestor::code)]").each { |node| assistant_link_paths(node) }
    fragment.to_html.html_safe
  end

  # The conversation page is the assistant itself: no topbar button, no right-hand column there.
  def show_assistant_dock?
    current_organization.present? && controller.controller_path != "member/assistant_conversations"
  end

  # One line under the card title, built from the payload only (no query per card). CYRA-907
  def proposal_detail(proposal)
    p = proposal.payload
    case proposal.kind
    when "create_ticket" then p["description"].to_s.truncate(160)
    when "comment_ticket" then p["body"].to_s.truncate(160)
    when "change_ticket_status" then "#{p['from_label']} → #{p['status_label']}"
    when "change_ticket_priority" then "#{p['from_label']} → #{p['priority_label']}"
    when "assign_ticket" then t("member.assistant.proposals.assign_to", name: p["assignee_name"])
    when "create_todo" then t("member.assistant.proposals.on_list", name: p["list_name"])
    when "create_idea" then p["problem"].to_s.truncate(160)
    end
  end

  # Options for an editable choice of a card, from the same scopes the tools use. CYRA-907
  def proposal_choice_options(key)
    @proposal_choices ||= Assistant::Proposals::Choices.new(account: Current.account, organization: Current.organization)
    @proposal_choices.options(key)
  end

  # Wiring of a composer's microphone. open_panel: the floating panel reloads on the new bubble;
  # the conversation page shows it in place. CYRA-908
  def assistant_inline_voice_data(conversation, open_panel:)
    { controller: "ui--voice-inline",
      "ui--voice-inline-url-value": member_assistant_voice_path(conversation_id: conversation&.id),
      "ui--voice-inline-max-seconds-value": Assistant::Constants::VOICE_MAX_SECONDS,
      "ui--voice-inline-open-panel-value": open_panel,
      "ui--voice-inline-labels-value": assistant_inline_voice_labels.to_json }
  end

  # A microphone shows only where transcription can answer: voice switched on in Valhalla and a
  # transcription model to call. One rule for every field and for the assistant's composers.
  def dictation_available?
    !Ai::Feature.disabled?(:assistant_voice) && Ai::Configuration.current.transcription_configured?
  end

  # Microphone that dictates into a text field: the recording goes to the dictation endpoint and
  # its text comes back into the field.
  def dictation_voice_data
    { controller: "ui--voice-inline",
      "ui--voice-inline-url-value": member_assistant_dictation_path,
      "ui--voice-inline-max-seconds-value": Assistant::Constants::VOICE_MAX_SECONDS,
      "ui--voice-inline-open-panel-value": false,
      "ui--voice-inline-dictate-value": true,
      "ui--voice-inline-labels-value": assistant_inline_voice_labels.merge(sending: t("member.assistant.voice.transcribing")).to_json }
  end

  # Words the panel's microphone writes on its own strip. CYRA-908
  def assistant_inline_voice_labels
    { silent: t("member.assistant.voice.panel_silent"), sending: t("member.assistant.voice.sending"),
      denied: t("member.assistant.voice.denied_title"), failed: t("member.assistant.voice.failed_title") }
  end

  private

  # Bolla d'errore (CYRA-436): un messaggio distinto per categoria — problema momentaneo (:unavailable,
  # riprova) o risposta non prodotta (:no_answer, riformula) — e SEMPRE il collegamento all'elenco delle
  # guide, così chi riceve l'errore ha comunque una strada per cavarsela da solo.
  # A spoken message waiting for Whisper, or one it could not turn into text. CYRA-908
  def assistant_voice_html(message)
    return tag.span(t("member.assistant.voice.transcribing"), class: "text-gray-500 dark:text-zinc-400 motion-safe:animate-pulse") if
      message.status_transcribing?

    tag.p(t("member.assistant.voice.#{message.error_kind == :not_heard ? 'not_heard' : 'failed'}"), class: "text-red-600 dark:text-red-400")
  end

  def assistant_failed_html(message)
    safe_join([
      tag.p(t("member.assistant.panel.failed.#{message.error_kind}"), class: "text-red-600 dark:text-red-400"),
      tag.p(link_to(t("member.assistant.panel.failed.guides"), member_guides_path, class: LINK_CLASS),
            class: "mt-1.5 text-[12.5px]")
    ])
  end

  # Un anchor sopravvive solo se punta a una pagina che l'utente può DAVVERO aprire; altrimenti resta
  # la sua etichetta, come testo.
  def assistant_filter_anchor(anchor)
    if assistant_catalog_paths.include?(anchor["href"].to_s)
      anchor["class"] = LINK_CLASS
    else
      anchor.replace(Nokogiri::XML::Text.new(anchor.text, anchor.document))
    end
  end

  # L'escape viene PRIMA della sostituzione: un percorso non contiene caratteri da escapare, quindi
  # l'ordine è sicuro e il resto della frase resta testo escapato.
  def assistant_link_paths(node)
    return unless node.content.match?(ASSISTANT_PATH)

    html = CGI.escapeHTML(node.content).gsub(ASSISTANT_PATH) do |path|
      assistant_catalog_paths.include?(path) ? link_to(path, path, class: LINK_CLASS) : path
    end
    node.replace(Nokogiri::HTML5.fragment(html))
  end

  # I percorsi che l'utente può DAVVERO usare: solo quelli del suo catalogo RBAC diventano link. Così
  # né un'allucinazione né una risposta manipolata linkano una funzione fuori dai suoi permessi (una
  # rotta reale ma vietata non passa). Memoizzato per-richiesta (una sola costruzione del catalogo).
  def assistant_catalog_paths
    @_assistant_catalog_paths ||=
      if Current.account && Current.organization
        Assistant::BuildCatalog.call(account: Current.account, organization: Current.organization)
                               .map(&:path).to_set
      else
        Set.new
      end
  end
end
