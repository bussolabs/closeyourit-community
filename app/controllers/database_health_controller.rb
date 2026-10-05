# frozen_string_literal: true

# Prontezza del DATABASE PRIMARY, l'endpoint che kamal-proxy interroga al rollout per decidere se
# deviare il traffico sul contenitore nuovo (CYRA-754). NON è `/up`: quello resta liveness PURA
# dell'app — lo usano il Docker HEALTHCHECK dell'immagine (e quindi Sablier, per risvegliare lo
# staging) e gli smoke della CI, e un check che può fallire per cause esterne falserebbe la liveness.
# Vedi knowledge-base/global/health-version.md.
#
# Pubblico e senza auth come /up, /version, /up/workers, /up/recurring e /up/embedding → eredita da
# ActionController::Base per saltare auth e org context. Non espone nulla di sensibile: solo l'esito e
# il tipo di guasto, mai il messaggio del driver (che nomina host, porta e nome del database).
class DatabaseHealthController < ActionController::Base
  def show
    result = Ops::DatabaseHealth.call

    if result.available?
      render json: { database: "up" }, status: :ok
    else
      render json: { database: "down", error: result.error }, status: :service_unavailable
    end
  end
end
