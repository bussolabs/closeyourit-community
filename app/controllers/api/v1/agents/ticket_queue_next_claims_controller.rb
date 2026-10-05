# frozen_string_literal: true

module Api
  module V1
    module Agents
      # Presa in carico atomica della coda (CYRA-588): sceglie il candidato E lo prende in carico in una
      # sola richiesta, così due postazioni sulla stessa coda ottengono ticket diversi invece di
      # contendersi la testa. Additivo: GET /ticket_queue + POST /ticket_queue/claims restano il percorso
      # in due passi, che nessun client è costretto ad abbandonare.
      #
      # La risposta è quella del claim in due passi — il lease più attempt_id — con in più `candidate`:
      # chi salta il preflight non ha mai visto lo snapshot del ticket e senza non avrebbe di che
      # lavorare. Additiva anche nella forma: un client che già legge il claim legge questa senza
      # cambiare niente, e il candidato usa lo stesso serializer del preflight.
      class TicketQueueNextClaimsController < Api::V1::Leases::BaseController
        def create
          result = ::Agents::TicketQueues::ClaimNext.call(
            organization: Current.organization,
            project_key: params[:project_key],
            host: Current.agent_host,
            params: next_claim_params
          )
          return render_lease_error(result.error) if result.err?

          outcome = result.value
          # Coda vuota: 200 con data null, la stessa forma con cui il preflight dice «niente lavoro».
          return render_ok(nil) unless outcome

          render json: { data: payload(outcome) }, status: outcome.fresh_acquisition ? :created : :ok
        end

        private

        # ttl_seconds NON arriva dal client, a differenza del claim in due passi: lì la fase è già nota
        # (l'ha vista nel preflight), qui la sceglie il server insieme al ticket e con lei il timeout
        # autoritativo del PhaseProfile. Un client non può dichiarare il TTL di una fase che ancora non sa.
        def next_claim_params
          ActionController::Parameters.new(request.request_parameters)
                                      .permit(:host_id, :run_id)
                                      .to_h.symbolize_keys
        end

        # Il candidato NON porta selection_token né estimated_cost, che sono proprietà della selezione e
        # non del ticket: qui la selezione è già stata spesa dalla presa in carico. Un token restituito
        # dopo il lease non servirebbe comunque a deferire — il defer rifiuta un ticket con lease attivo,
        # e la fase appena presa non è più quella pronta.
        def payload(outcome)
          AgentLeaseSerializer.new(outcome.lease).as_json.merge(
            "attempt_id" => outcome.attempt.id,
            # CYRA-921: which engine the machine must use to review before delivering.
            "review_mode" => outcome.attempt.host.review_mode,
            # CYRA-921: which engine does the work, frozen on the attempt at claim time.
            "work_engine" => outcome.attempt.runtime,
            "candidate" => AgentTicketCandidateSerializer.new(outcome.ticket).as_json
          )
        end
      end
    end
  end
end
