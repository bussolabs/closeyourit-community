# frozen_string_literal: true

# Liveness del SERVIZIO DI EMBEDDING vista da Rails, cioè dalla stessa strada che percorrono le
# feature vere (stesso EMBED_BASE_URL, stesso client). NON è `/up`: quello resta liveness PURA
# dell'app e non deve dipendere da un servizio esterno, altrimenti Kamal considera l'app malata
# quando è sana. Vedi knowledge-base/global/health-version.md.
#
# Perché serve (CYEM-2): la smoke del repo embedding gira DENTRO il container e prova solo che il
# servizio parli a se stesso, quindi non vede i guasti sul PERCORSO fra chi chiede e chi risponde —
# che è esattamente com'è andata: un redeploy di Rails cambiava il nome del container e spezzava la
# rotta, mentre tutte le verifiche restavano verdi. Uptime non può sostituirla perché Uptime::Ping
# rifiuta gli indirizzi privati e il servizio vive sulla rete interna.
#
# Pubblico e senza auth come /up, /version e /up/workers → eredita da ActionController::Base per
# saltare auth e org context. Non espone nulla di sensibile: solo esito e codice d'errore.
class EmbeddingHealthController < ActionController::Base
  def show
    if Ai::Feature.disabled?(:embeddings)
      # Spento di proposito ≠ guasto: 200, così lo smoke di un'installazione senza embedding non
      # fallisce. Chi legge distingue dal campo `embedding`.
      return render json: { embedding: "disabled" }, status: :ok
    end

    result = Embeddings::EmbedText.call(text: Embeddings::CheckServiceHealthJob::PROBE_TEXT)

    if result.ok?
      render json: { embedding: "up", dimensions: result.value.length }, status: :ok
    else
      render json: { embedding: "down", code: result.error.code }, status: :service_unavailable
    end
  end
end
