# frozen_string_literal: true

# Enqueue di una richiesta AI asincrona: crea la Ai::Request pending, accoda Ai::RunJob e risponde
# 202 con l'id che la UI polla su /member/ai/requests/:id. I guard (visibilità, permessi, flag)
# restano nel controller chiamante, PRIMA dell'enqueue.
module AiEnqueueing
  extend ActiveSupport::Concern

  private

  # CYRA-812 — il perimetro con cui parte una domanda AI asincrona, nella forma che il lavoro poi
  # ripassa dal perimetro di quel momento (Ai::RunJob#narrowed_scope). Tre cose e non una:
  #
  #   - l'ELENCO esplicito di progetti e gruppi, anche per chi ha accesso pieno, DICHIARATO completo
  #     (`scope_listed`): senza, un progetto nato dopo la domanda entrerebbe nel perimetro di una
  #     domanda che non lo comprendeva, perché l'elenco vuoto di un owner senza progetti è identico
  #     a quello con cui i lavori più vecchi dicevano «tutta l'organizzazione»;
  #   - il flag di accesso pieno, perché la knowledge base non appartiene a un progetto;
  #   - CHI ha autorizzato — `Current.true_account` con un god che impersona, perché il perimetro era
  #     il suo: senza quell'id il lavoro ricontrollerebbe gli accessi dell'impersonato, che sono altri.
  def ai_scope_args
    actor = Current.true_account || Current.account
    snapshot = Authorization::ScopeSnapshot.capture(account: actor, organization: Current.organization)

    { actor_account_id: actor.id, full_access: snapshot.full_access, scope_listed: true,
      project_ids: snapshot.project_ids, group_ids: snapshot.group_ids }
  end

  # Il servizio che serve a questo kind non è collegato dall'organizzazione? Non si crea la richiesta
  # e non si accoda niente (CYRA-548): il fallimento arriverebbe comunque, ma dopo aver lasciato una
  # riga fallita nello storico delle richieste — dove chi legge cerca i propri tentativi, non la
  # nostra configurazione mancante. La risposta è la stessa forma di errore degli altri guard, così
  # il JS che polla la mostra senza sapere niente di nuovo.
  def enqueue_ai_request!(kind:, args:)
    error = missing_integration_error(kind)
    return render json: { error: { code: error.code, message: error.message } }, status: error.status if error

    request_record = Ai::Request.create!(
      account: Current.account, organization: Current.organization, kind:, args:
    )
    Ai::RunJob.perform_later(request_record)
    render json: { data: { request_id: request_record.id, status: "pending" } }, status: :accepted
  end

  def missing_integration_error(kind)
    provider = Ai::Request.provider_for(kind)
    return if provider.nil?
    return if Integrations::Resolve.connected?(organization: Current.organization, provider: provider)

    Integrations::Providers.not_connected_error(provider)
  end
end
